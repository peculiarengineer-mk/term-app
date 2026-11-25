import Foundation
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

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostname : trimmed
    }

    var connectionSubtitle: String {
        let userPart = username.isEmpty ? "" : "\(username)@"
        let portPart = port == 22 ? "" : ":\(port)"
        return "\(userPart)\(hostname)\(portPart)"
    }

    @MainActor
    init(host: Host, sessionManager: SessionManager) {
        self.id = host.id
        self.label = host.label
        self.hostname = host.hostname
        self.port = host.port
        self.username = host.username
        self.authMethod = host.authMethod
        self.keyID = host.keyID
        self.activeSession = sessionManager.connectedSession(for: host.id)?.session
    }
}

enum AgentRemoteError: LocalizedError {
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
            guard let password = HostSecrets.password(for: target.id) else {
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
            guard let password = HostSecrets.password(for: target.id) else {
                throw AgentRemoteError.needsInteractiveAuth(
                    "Credentials for \(target.displayName) require an active session."
                )
            }
            return .password(password)
        }
    }

    /// Host-key verifier that ONLY trusts already-known fingerprints so background scans never pop TOFU dialogs.
    static func trustedOnlyHostKeyVerifier(
        host: String,
        port: Int,
        knownHosts: KnownHostsStore = KnownHostsStore()
    ) -> @Sendable (HostKey) async -> HostKeyDecision {
        { presented in
            guard let stored = try? knownHosts.fingerprint(host: host, port: port) else {
                return .reject
            }
            return stored == presented.fingerprint ? .trust : .reject
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

        let auth = try buildAuth(for: target)
        let knownHosts = KnownHostsStore()
        let storedFingerprint = try? knownHosts.fingerprint(host: target.hostname, port: target.port)

        do {
            return try await SSHExec.runCommand(
                host: target.hostname,
                port: UInt16(clamping: max(1, target.port)),
                username: target.username,
                auth: auth,
                command: command,
                timeout: timeout,
                verifyHostKey: trustedOnlyHostKeyVerifier(
                    host: target.hostname,
                    port: target.port,
                    knownHosts: knownHosts
                )
            )
        } catch let error as SSHError {
            throw mapSSHError(error, target: target, hadStoredFingerprint: storedFingerprint != nil)
        }
    }

    private static func mapSSHError(
        _ error: SSHError,
        target: AgentHostTarget,
        hadStoredFingerprint: Bool
    ) -> Error {
        switch error {
        case .hostKeyRejected:
            if hadStoredFingerprint {
                return AgentRemoteError.hostKeyMismatch(
                    "Host key changed for \(target.displayName). Open a terminal session to verify."
                )
            }
            return AgentRemoteError.untrustedHostKey(
                "Host key for \(target.displayName) is not trusted yet. Connect once to trust it."
            )
        case .authenticationFailed:
            return AgentRemoteError.needsInteractiveAuth(
                "Authentication failed for \(target.displayName). Connect a terminal session to re-authenticate."
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
