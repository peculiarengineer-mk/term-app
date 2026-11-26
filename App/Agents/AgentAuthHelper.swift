import Foundation
import os
import Security
import SwiftData
import SwiftUI
import SSHKit
import Store
import TermUI

/// Sendable snapshot of a saved `Host` plus an optional connected `Session` for off-main-actor SSH exec.
struct AgentHostTarget: Sendable, Identifiable {
    let id: UUID
    let label: String
    let hostname: String
    let port: Int
    let username: String
    let authMethod: String
    let keyID: UUID?
    let activeSession: (any Session)?
    let jumpResolution: Result<[SSHOptionsBuilder.JumpHopSpec], AgentRemoteError>

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostname : trimmed
    }

    var connectionSubtitle: String {
        let userPart = username.isEmpty ? "" : "\(username)@"
        let portPart = port == 22 ? "" : ":\(port)"
        return "\(userPart)\(hostname)\(portPart)"
    }

    init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String = "root",
        authMethod: String,
        keyID: UUID? = nil,
        activeSession: (any Session)? = nil,
        jumpResolution: Result<[SSHOptionsBuilder.JumpHopSpec], AgentRemoteError> = .success([])
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyID = keyID
        self.activeSession = activeSession
        self.jumpResolution = jumpResolution
    }

    @MainActor
    init(
        host: Host,
        sessionManager: SessionManager,
        allHosts: [Host]? = nil,
        keyStore: KeyStore = KeyStore()
    ) {
        self.id = host.id
        self.label = host.label
        self.hostname = host.hostname
        self.port = host.port
        self.username = host.username
        self.authMethod = host.authMethod
        self.keyID = host.keyID
        self.activeSession = sessionManager.connectedSession(for: host.id)?.session

        let resolvedHosts = allHosts ?? (try? host.modelContext?.fetch(FetchDescriptor<Host>())) ?? []
        do {
            let specs = try SSHOptionsBuilder.buildJumpHopSpecs(
                for: host,
                allHosts: resolvedHosts,
                keyStore: keyStore
            )
            self.jumpResolution = .success(specs)
        } catch let error as SSHOptionsError {
            self.jumpResolution = .failure(Self.mapJumpOptionsError(error))
        } catch {
            self.jumpResolution = .failure(.commandFailed(error.localizedDescription))
        }
    }

    private static func mapJumpOptionsError(_ error: SSHOptionsError) -> AgentRemoteError {
        switch error {
        case .jumpHostMissingKey, .jumpHostSecureEnclaveUnavailable:
            .missingCredentials(error.localizedDescription)
        case .jumpHostEncryptedKeyNeedsPassphrase,
             .jumpHostMissingPassword,
             .jumpHostRequiresInteractiveAuth:
            .needsInteractiveAuth(error.localizedDescription)
        case .cycleDetected,
             .maxHopsExceeded,
             .jumpHostNotFound,
             .invalidJumpHostEndpoint:
            .commandFailed(error.localizedDescription)
        }
    }
}

enum AgentRemoteError: LocalizedError, Equatable {
    case missingCredentials(String)
    case needsInteractiveAuth(String)
    case untrustedHostKey(String)
    case hostKeyMismatch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let msg),
             .needsInteractiveAuth(let msg),
             .untrustedHostKey(let msg),
             .hostKeyMismatch(let msg),
             .commandFailed(let msg):
            msg
        }
    }

    var isAuthOrTrustIssue: Bool {
        switch self {
        case .missingCredentials, .needsInteractiveAuth, .untrustedHostKey, .hostKeyMismatch:
            true
        case .commandFailed:
            false
        }
    }
}

/// Non-interactive SSH auth & one-shot `exec` helper for background agent scans and folder browsing.
enum AgentAuthHelper {
    static let defaultTimeout: Duration = .seconds(10)
    private static let logger = Logger(subsystem: "com.peculiarengineer.termapp", category: "agent-auth")

    /// Builds `SSHAuth` non-interactively from `KeyStore` and `HostSecrets`, never prompting UI.
    static func buildAuth(for target: AgentHostTarget) throws -> SSHAuth {
        switch target.authMethod {
        case "key":
            let store = KeyStore()
            guard let keyID = target.keyID,
                  let key = try store.list().first(where: { $0.id == keyID }) else {
                throw AgentRemoteError.missingCredentials("SSH key not found for \(target.displayName).")
            }
            if key.type == .secureEnclaveP256 {
                let signer = try SecureEnclaveKey.signer(for: key, store: store)
                return .signer(publicKeyBlob: signer.publicKeyBlob, sign: signer.sign)
            }
            guard let pem = try store.privateKey(for: key) else {
                throw AgentRemoteError.missingCredentials("Private key data missing for \(key.name).")
            }
            let passphrase = try store.passphrase(for: key)
            if key.isEncrypted && passphrase == nil {
                throw AgentRemoteError.needsInteractiveAuth(
                    "Passphrase for \(key.name) is not saved. Connect to \(target.displayName) first."
                )
            }
            return .privateKey(pem: pem, passphrase: passphrase)

        case "password":
            guard let password = try HostSecrets.readPassword(for: target.id) else {
                throw AgentRemoteError.needsInteractiveAuth(
                    "No saved password for \(target.displayName). Connect a terminal session first."
                )
            }
            return .password(password)

        case "keyboardInteractive":
            throw AgentRemoteError.needsInteractiveAuth(
                "\(target.displayName) uses interactive 2FA. Connect a terminal session first."
            )

        default:
            throw AgentRemoteError.needsInteractiveAuth(
                "Unsupported authentication method for \(target.displayName). Connect a terminal session first."
            )
        }
    }

    private struct RejectedHostKeyInfo: Sendable {
        let displayName: String
        let hadStoredFingerprint: Bool
    }

    private struct VerifierErrorInfo: Sendable {
        let displayName: String
        let error: Error
    }

    /// Host-key verifier that ONLY trusts already-known fingerprints so background scans never pop TOFU dialogs.
    static func trustedOnlyHostKeyVerifier(
        host: String,
        port: Int,
        knownHosts: KnownHostsStore = KnownHostsStore()
    ) -> @Sendable (HostKey) async -> HostKeyDecision {
        trustedOnlyHostKeyVerifier(
            host: host,
            port: port,
            displayName: host,
            knownHosts: knownHosts,
            onReject: nil,
            onError: nil
        )
    }

    private static func trustedOnlyHostKeyVerifier(
        host: String,
        port: Int,
        displayName: String,
        knownHosts: KnownHostsStore,
        onReject: (@Sendable (RejectedHostKeyInfo) -> Void)?,
        onError: (@Sendable (VerifierErrorInfo) -> Void)?
    ) -> @Sendable (HostKey) async -> HostKeyDecision {
        { presented in
            do {
                guard let stored = try knownHosts.fingerprint(host: host, port: port) else {
                    onReject?(RejectedHostKeyInfo(displayName: displayName, hadStoredFingerprint: false))
                    return .reject
                }
                if stored == presented.fingerprint {
                    return .trust
                }
                onReject?(RejectedHostKeyInfo(displayName: displayName, hadStoredFingerprint: true))
                return .reject
            } catch let error as KeychainError where error.status == errSecItemNotFound {
                onReject?(RejectedHostKeyInfo(displayName: displayName, hadStoredFingerprint: false))
                return .reject
            } catch {
                logger.error("Failed reading known host key for \(host, privacy: .private):\(port): \(String(describing: error), privacy: .public)")
                onError?(VerifierErrorInfo(displayName: displayName, error: error))
                return .reject
            }
        }
    }

    /// Runs `command` via an active connected `LiveSession` when available, otherwise via ephemeral `SSHExec`.
    static func exec(
        _ command: String,
        on target: AgentHostTarget,
        timeout: Duration = defaultTimeout
    ) async throws -> SSHExecResult {
        if let activeSession = target.activeSession {
            do {
                return try await activeSession.exec(command, timeout: timeout)
            } catch SSHError.notConnected, SSHError.closed {
                // Fall back to a fresh exec connection if the live session dropped right before the call.
            }
        }

        let jumpSpecs = try target.jumpResolution.get()
        let auth = try buildAuth(for: target)
        let knownHosts = KnownHostsStore()
        let storedFingerprint: String?
        do {
            storedFingerprint = try knownHosts.fingerprint(host: target.hostname, port: target.port)
        } catch let error as KeychainError where error.status == errSecItemNotFound {
            storedFingerprint = nil
        } catch {
            throw AgentRemoteError.commandFailed(keychainHostKeyErrorMessage(error, displayName: target.displayName))
        }

        let rejectedHostKey = OSAllocatedUnfairLock<RejectedHostKeyInfo?>(initialState: nil)
        let verifierError = OSAllocatedUnfairLock<VerifierErrorInfo?>(initialState: nil)
        let recordReject: @Sendable (RejectedHostKeyInfo) -> Void = { info in
            rejectedHostKey.withLock {
                if $0 == nil { $0 = info }
            }
        }
        let recordError: @Sendable (VerifierErrorInfo) -> Void = { info in
            verifierError.withLock {
                if $0 == nil { $0 = info }
            }
        }
        let jumpHops = jumpSpecs.map { spec in
            spec.makeJumpHop(
                verifyHostKey: trustedOnlyHostKeyVerifier(
                    host: spec.host,
                    port: Int(spec.port),
                    displayName: "jump host \(spec.displayName)",
                    knownHosts: knownHosts,
                    onReject: recordReject,
                    onError: recordError
                )
            )
        }

        do {
            return try await SSHExec.runCommand(
                host: target.hostname,
                port: UInt16(clamping: max(1, target.port)),
                username: target.username,
                auth: auth,
                command: command,
                timeout: timeout,
                jumpHops: jumpHops,
                verifyHostKey: trustedOnlyHostKeyVerifier(
                    host: target.hostname,
                    port: target.port,
                    displayName: target.displayName,
                    knownHosts: knownHosts,
                    onReject: recordReject,
                    onError: recordError
                )
            )
        } catch let error as SSHError {
            if case .hostKeyRejected = error,
               let keychainError = verifierError.withLock({ $0 }) {
                throw AgentRemoteError.commandFailed(
                    keychainHostKeyErrorMessage(keychainError.error, displayName: keychainError.displayName)
                )
            }
            let rejected = rejectedHostKey.withLock { $0 }
            throw mapSSHError(
                error,
                target: target,
                hasJumpHops: !jumpHops.isEmpty,
                rejectedDisplayName: rejected?.displayName ?? target.displayName,
                hadStoredFingerprint: rejected?.hadStoredFingerprint ?? (storedFingerprint != nil)
            )
        }
    }

    private static func keychainHostKeyErrorMessage(_ error: Error, displayName: String) -> String {
        if let keychainError = error as? KeychainError {
            return "Could not read trusted host key for \(displayName) from Keychain (OSStatus \(keychainError.status))."
        }
        return "Could not read trusted host key for \(displayName): \(error.localizedDescription)"
    }

    private static func mapSSHError(
        _ error: SSHError,
        target: AgentHostTarget,
        hasJumpHops: Bool,
        rejectedDisplayName: String,
        hadStoredFingerprint: Bool
    ) -> Error {
        switch error {
        case .hostKeyRejected:
            if hadStoredFingerprint {
                return AgentRemoteError.hostKeyMismatch(
                    "Host key changed for \(rejectedDisplayName). Open a terminal session to verify."
                )
            }
            return AgentRemoteError.untrustedHostKey(
                "Host key for \(rejectedDisplayName) is not trusted yet. Connect once to trust it."
            )
        case .authenticationFailed:
            let subject = hasJumpHops ? "\(target.displayName) or its jump host" : target.displayName
            return AgentRemoteError.needsInteractiveAuth(
                "Authentication failed for \(subject). Connect a terminal session to re-authenticate."
            )
        case .timeout:
            return AgentRemoteError.commandFailed("\(target.displayName) timed out.")
        case .connectionFailed(let msg):
            return AgentRemoteError.commandFailed("Could not reach \(target.displayName): \(msg)")
        case .channelFailed(let msg), .protocolError(_, let msg):
            return AgentRemoteError.commandFailed(msg)
        case .notConnected, .closed:
            return AgentRemoteError.commandFailed("Connection to \(target.displayName) closed.")
        }
    }
}

/// Apple Pro Dark visual and formatting helpers shared across all AI Agent views.
@MainActor
enum AgentVisuals {
    static let appleProAmber = TerminalTheme.appleProDark.accentColor
    static let slateColor = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
    static let activeGreen = Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func agentTint(for descriptor: AIAgentDescriptor) -> Color {
        tint(forToken: descriptor.colorToken)
    }

    static func agentTint(forSlug slug: String) -> Color {
        tint(forToken: agentDescriptor(forSlug: slug).colorToken)
    }

    static func agentSymbol(for descriptor: AIAgentDescriptor) -> String {
        let trimmed = descriptor.symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "terminal" : trimmed
    }

    static func agentSymbol(forSlug slug: String) -> String {
        agentSymbol(for: agentDescriptor(forSlug: slug))
    }

    static func agentDescriptor(forSlug slug: String) -> AIAgentDescriptor {
        let normalized = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let presets = HostProjectStore.allPresets()
        if let exact = presets.first(where: { $0.slug.lowercased() == normalized || $0.id.lowercased() == normalized }) {
            return exact
        }
        if let builtIn = BuiltInAIAgent(rawValue: normalized) {
            return AIAgentDescriptor(builtIn: builtIn)
        }
        let fallbackName = normalized.isEmpty ? "Agent" : normalized.capitalized
        return AIAgentDescriptor(
            id: normalized.isEmpty ? "custom" : normalized,
            slug: normalized.isEmpty ? "custom" : normalized,
            name: fallbackName,
            command: normalized.isEmpty ? "sh" : normalized,
            defaultArgs: "",
            symbolName: "terminal",
            colorToken: "slate",
            isBuiltIn: false,
            builtIn: nil
        )
    }

    static func relativeActivityString(from date: Date?, now: Date = .now) -> String {
        guard let date else { return "Unknown" }
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 10 {
            return "Just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static func tint(forToken token: String) -> Color {
        switch token.lowercased() {
        case "amber": appleProAmber
        case "cyan": Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "green": activeGreen
        case "blue": Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
        case "purple": Color(red: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0)
        default: slateColor
        }
    }
}
