import SwiftUI
import SSHKit
import Store

@MainActor @Observable
final class HostConnectionModel {
    enum Phase {
        case input(InputRequest)
        case connecting
        case prompt(HostKey)
        case mismatch(stored: String, presented: HostKey)
        case connected(SessionBridge)
        case failed(String)
        case keyMissing(keyName: String?)
    }

    enum Purpose { case password, passphrase, keyboardInteractive }
    struct InputRequest: Identifiable {
        let id = UUID()
        let purpose: Purpose
        let title: String
        let instruction: String
        let items: [Prompt.Item]
        let prefill: [String]
    }

    var phase: Phase = .connecting
    private var pendingAnswers: CheckedContinuation<[String], Never>?
    private var kiGeneration = 0
    private var trustGeneration = 0
    /// Bumped by every connect(); a prompt from an older connection is ignored.
    private var attempt = 0
    private var kiRound = 0
    private var typedPassphrase: String?
    private var savePassphraseOnSuccess = false
    private var decision: CheckedContinuation<HostKeyDecision, Never>?
    private var task: Task<Void, Never>?
    private var connection: SSHConnection?
    /// Called once connected; the receiver owns the session from then on (T8: SessionManager).
    var onConnected: ((SSHConnection, SessionBridge) -> Void)?
    /// Called when a connect attempt fails; the flag is true for network-level errors worth retrying (T9).
    var onFailed: ((Bool) -> Void)?
    private var handedOff = false
    private var hostUpdatedAt: Date
    private var lastFailedWithAuth = false
    private var bypassSavedSecrets = false

    // One per line: @Observable's tracking accessor cannot attach to a multi-variable declaration.
    private(set) var hostname: String
    private(set) var port: Int
    private(set) var username: String
    private(set) var authMethod: String
    private(set) var keyID: UUID?
    private(set) var tmux: String?
    private(set) var title: String
    let hostID: UUID
    private let known = KnownHostsStore()
    private var typedPassword: String?

    init(host: Host) {
        hostname = host.hostname; port = host.port; username = host.username
        authMethod = host.authMethod; keyID = host.keyID; tmux = host.tmuxCommand; hostID = host.id
        title = host.label.isEmpty ? host.hostname : host.label
        hostUpdatedAt = host.updatedAt
    }

    /// Re-reads the host's fields, e.g. after the user edited it from the key-missing screen.
    func refresh(from host: Host) {
        if host.updatedAt != hostUpdatedAt {
            hostUpdatedAt = host.updatedAt
            lastFailedWithAuth = false
            bypassSavedSecrets = false
        }
        hostname = host.hostname; port = host.port; username = host.username
        authMethod = host.authMethod; keyID = host.keyID; tmux = host.tmuxCommand
        title = host.label.isEmpty ? host.hostname : host.label
    }

    func start() {
        if authMethod == "key" {
            let store = KeyStore()
            let key = keyID.flatMap { id in (try? store.list())?.first(where: { $0.id == id }) }
            guard let key, ((try? store.privateKey(for: key)) ?? nil) != nil else {
                phase = .keyMissing(keyName: key?.name)
                return
            }
            if key.isEncrypted, typedPassphrase == nil,
               bypassSavedSecrets || ((try? store.passphrase(for: key)) ?? nil) == nil {
                phase = .input(InputRequest(purpose: .passphrase, title: "Passphrase for \(key.name)",
                                            instruction: "", items: [.init(text: "Passphrase", echo: false)], prefill: [""]))
                return
            }
        }
        if authMethod == "password", typedPassword == nil,
           bypassSavedSecrets || HostSecrets.password(for: hostID) == nil {
            phase = .input(InputRequest(purpose: .password, title: "Password for \(username)@\(hostname)",
                                        instruction: "", items: [.init(text: "Password", echo: false)], prefill: [""]))
            return
        }
        connect()
    }

    /// Clears anything typed earlier, so a failed login asks again (bypassing wrong saved secrets).
    func retry() {
        if lastFailedWithAuth { bypassSavedSecrets = true }
        lastFailedWithAuth = false
        typedPassword = nil
        typedPassphrase = nil
        savePassphraseOnSuccess = false
        start()
    }

    func submitInput(_ request: InputRequest, answers: [String], savePassphrase: Bool = false) {
        switch request.purpose {
        case .password: typedPassword = answers.first ?? ""; connect()
        case .passphrase:
            typedPassphrase = answers.first ?? ""
            savePassphraseOnSuccess = savePassphrase
            connect()
        case .keyboardInteractive:
            phase = .connecting
            resolveInput(answers)
        }
    }

    func cancelInput(_ request: InputRequest) {
        switch request.purpose {
        case .keyboardInteractive:
            phase = .failed("Cancelled")  // kept by connect()'s catch
            resolveInput([])
            task?.cancel()  // stop any further server rounds from re-opening the form
        default: phase = .failed("Cancelled")
        }
    }

    private func resolveInput(_ answers: [String]) {
        pendingAnswers?.resume(returning: answers)
        pendingAnswers = nil
    }

    /// Shows one server prompt set. The saved password pre-fills only a non-echo
    /// password item in the first round.
    private func askPrompt(_ prompt: Prompt, attempt promptAttempt: Int) async -> [String] {
        // A round from a superseded or cancelled connection must not touch the current one's state.
        if Task.isCancelled || promptAttempt != attempt { return [] }
        let saved = bypassSavedSecrets ? nil : HostSecrets.password(for: hostID)
        let first = kiRound == 0
        kiRound += 1
        let prefill = prompt.items.map { item -> String in
            first && !item.echo && item.text.lowercased().contains("password") ? (saved ?? "") : ""
        }
        if prompt.items.isEmpty { return [] }
        resolveInput([])  // never leave an earlier round's continuation pending
        kiGeneration += 1
        let generation = kiGeneration
        // SSHKit cancels this handler when the server-side wait (120 s) runs out or the connection
        // closes; resume with no answers then and take the stale form down.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                pendingAnswers = c
                phase = .input(InputRequest(purpose: .keyboardInteractive,
                                            title: prompt.name.isEmpty ? "Authentication" : prompt.name,
                                            instruction: prompt.instruction + (prompt.instruction.isEmpty ? "" : "\n") + "Respond within 2 minutes.",
                                            items: prompt.items, prefill: prefill))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // Only this round: a later round or connection may own the pending continuation now.
                guard let self, self.kiGeneration == generation, self.pendingAnswers != nil else { return }
                self.phase = .failed("Timed out waiting for input.")
                self.resolveInput([])
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? SSHError else { return error.localizedDescription }
        switch e {
        case .connectionFailed(let m): return "Could not connect: \(m)"
        case .timeout: return "The connection timed out."
        case .hostKeyRejected: return "The host key was not accepted."
        case .authenticationFailed(let m):
            return m.isEmpty || m == "Authentication failed" ? "Authentication failed." : "Authentication failed: \(m)"
        case .protocolError(_, let m): return "SSH protocol error: \(m)"
        case .channelFailed(let m): return "Could not open a session: \(m)"
        case .notConnected: return "Not connected."
        case .closed: return "The connection was closed."
        }
    }

    private func buildAuth() throws -> SSHAuth {
        let saved = typedPassword ?? (bypassSavedSecrets ? nil : HostSecrets.password(for: hostID)) ?? ""
        kiRound = 0
        switch authMethod {
        case "key":
            let store = KeyStore()
            guard let key = try store.list().first(where: { $0.id == keyID }),
                  let pem = try store.privateKey(for: key) else {
                throw KeyStoreError.keyMissing
            }
            if key.type == .secureEnclaveP256 {
                let s = try SecureEnclaveKey.signer(for: key, store: store)
                return .signer(publicKeyBlob: s.publicKeyBlob, sign: s.sign)
            }
            let phrase = if let typedPassphrase {
                typedPassphrase
            } else {
                bypassSavedSecrets ? nil : try store.passphrase(for: key)
            }
            return .privateKey(pem: pem, passphrase: phrase)
        case "keyboardInteractive":
            let current = attempt
            return .keyboardInteractive { [weak self] prompt in
                guard let self else { return [] }
                return await self.askPrompt(prompt, attempt: current)
            }
        default:
            return .password(saved)
        }
    }

    func connect() {
        attempt += 1
        lastFailedWithAuth = false
        resolve(.reject)
        resolveInput([])
        task?.cancel()
        let old = handedOff ? nil : connection
        connection = nil
        handedOff = false
        Task { await old?.close() }
        phase = .connecting
        let auth: SSHAuth
        do { auth = try buildAuth() }
        catch KeyStoreError.keyMissing {
            let name = (try? KeyStore().list())?.first(where: { $0.id == keyID })?.name
            phase = .keyMissing(keyName: name); return
        }
        catch KeyStoreError.secureEnclaveUnavailable {
            phase = .failed("This device has no Secure Enclave, so it can't use this key."); return
        }
        catch { phase = .failed("\(error.localizedDescription)"); return }
        let conn = SSHConnection(host: hostname, port: UInt16(clamping: port), username: username, auth: auth)
        connection = conn
        let known = self.known, host = hostname, port = self.port, currentAttempt = attempt
        task = Task {
            do {
                try await conn.connect { [weak self] key in
                    let stored: String?
                    do { stored = try known.fingerprint(host: host, port: port) } catch { return .reject }
                    if let stored {
                        if stored == key.fingerprint { return .trust }
                        await self?.showMismatch(stored: stored, presented: key, attempt: currentAttempt)
                        return .reject  // blocked: never continue on a changed key
                    }
                    guard let self else { return .reject }
                    return await self.askTrust(key, attempt: currentAttempt)
                }
                if Task.isCancelled { await conn.close(); return }
                let bridge = SessionBridge(session: conn)
                phase = .connected(bridge)
                handedOff = true  // the connection now belongs to the receiver; teardown must not close it
                persistTypedPassphrase()
                onConnected?(conn, bridge)
            } catch {
                if Task.isCancelled { return }  // superseded: the new connection owns any pending prompt
                resolveInput([])
                if case .mismatch = phase { return }  // the mismatch screen is already showing
                if case .failed = phase { return }  // keep the original message
                if case .prompt = phase { phase = .failed("Cancelled") ; return }
                if let e = error as? SSHError, case .authenticationFailed = e { lastFailedWithAuth = true }
                phase = .failed(Self.describe(error))
                var network = false
                if let e = error as? SSHError {
                    switch e {
                    case .connectionFailed, .timeout: network = true
                    // libssh2 socket and banner failures: the network dropped mid-handshake. (KEX failures,
                    // server disconnects and the synthetic -1 are not retried: they fail the same way again.)
                    case .protocolError(let code, _): network = [-2, -3, -7, -30, -43].contains(code)
                    default: break
                    }
                }
                onFailed?(network)
            }
        }
    }

    /// Saves the typed passphrase after a successful connect; a failure here never fails the connection.
    private func persistTypedPassphrase() {
        guard savePassphraseOnSuccess, let phrase = typedPassphrase, !phrase.isEmpty else { return }
        savePassphraseOnSuccess = false
        let store = KeyStore()
        guard let key = (try? store.list())?.first(where: { $0.id == keyID }) else { return }
        try? store.savePassphrase(phrase, for: key)
    }

    private func showMismatch(stored: String, presented: HostKey, attempt mismatchAttempt: Int) {
        guard !Task.isCancelled, mismatchAttempt == attempt else { return }
        phase = .mismatch(stored: stored, presented: presented)
    }

    private func askTrust(_ key: HostKey, attempt trustAttempt: Int) async -> HostKeyDecision {
        if Task.isCancelled || trustAttempt != attempt { return .reject }
        resolve(.reject)  // never leave an earlier continuation pending
        trustGeneration += 1
        let generation = trustGeneration
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled || trustAttempt != attempt {
                    c.resume(returning: .reject)
                    return
                }
                decision = c
                phase = .prompt(key)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.trustGeneration == generation, self.decision != nil else { return }
                if case .prompt = self.phase { self.phase = .failed("Cancelled") }
                self.resolve(.reject)
            }
        }
    }

    func trust(_ key: HostKey) {
        do { try known.trust(host: hostname, port: port, fingerprint: key.fingerprint, synchronizable: try syncForFingerprint()) }
        catch { phase = .failed("Could not store the host key: \(error.localizedDescription)"); resolve(.reject); return }
        phase = .connecting
        resolve(.trust)
    }

    /// A save never turns an already-synced fingerprint local. A failed lookup throws rather than
    /// guessing "local", because saving local would delete the synced copy everywhere.
    private func syncForFingerprint() throws -> Bool {
        if AppContainer.syncEnabledAtLaunch { return true }
        let account = "\(hostname.lowercased()):\(port)"
        return try KeychainStore().readAll(service: KeychainService.knownHosts)
            .contains { $0.account == account && $0.synchronizable }
    }

    func cancelPrompt() { resolve(.reject) }

    private func resolve(_ d: HostKeyDecision) {
        decision?.resume(returning: d)
        decision = nil
    }

    func replaceStoredKey(with key: HostKey) {
        do {
            try known.trust(host: hostname, port: port, fingerprint: key.fingerprint, synchronizable: try syncForFingerprint())
            connect()
        } catch { phase = .failed("Could not replace the host key: \(error.localizedDescription)") }
    }

    func teardown() {
        resolve(.reject)
        resolveInput([])
        task?.cancel()
        task = nil
        let c = handedOff ? nil : connection
        connection = nil
        Task { await c?.close() }
    }
}
