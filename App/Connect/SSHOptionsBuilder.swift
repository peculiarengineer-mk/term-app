import CryptoKit
import Foundation
import SSHKit
import Store

/// User-facing errors raised when resolving ProxyJump bastion chains or jump credentials.
enum SSHOptionsError: LocalizedError, Equatable, Sendable {
    case cycleDetected
    case maxHopsExceeded(Int)
    case jumpHostNotFound(targetName: String)
    case invalidJumpHostEndpoint(jumpName: String)
    case jumpHostMissingKey(jumpName: String)
    case jumpHostEncryptedKeyNeedsPassphrase(jumpName: String, keyName: String)
    case jumpHostSecureEnclaveUnavailable(jumpName: String)
    case jumpHostMissingPassword(jumpName: String)
    case jumpHostRequiresInteractiveAuth(jumpName: String)

    var errorDescription: String? {
        switch self {
        case .cycleDetected:
            "ProxyJump configuration contains a cycle. Check your Jump Host settings."
        case .maxHopsExceeded(let maxHops):
            "ProxyJump chain exceeds the maximum of \(maxHops) hops."
        case .jumpHostNotFound(let targetName):
            "The Jump Host configured for \(targetName) could not be found. Edit \(targetName) to choose a valid Jump Host."
        case .invalidJumpHostEndpoint(let jumpName):
            "Jump host \"\(jumpName)\" has an invalid hostname, username, or port. Edit \"\(jumpName)\" first."
        case .jumpHostMissingKey(let jumpName):
            "Jump host \"\(jumpName)\" is missing its SSH key. Edit \"\(jumpName)\" or import the key on this device first."
        case .jumpHostEncryptedKeyNeedsPassphrase(let jumpName, let keyName):
            "Jump host \"\(jumpName)\" uses encrypted key \"\(keyName)\" without a saved passphrase. Connect to \"\(jumpName)\" directly first and save its passphrase."
        case .jumpHostSecureEnclaveUnavailable(let jumpName):
            "Jump host \"\(jumpName)\" uses a Secure Enclave key, which is unavailable on this device."
        case .jumpHostMissingPassword(let jumpName):
            "Jump host \"\(jumpName)\" does not have a saved password. Edit \"\(jumpName)\" to save its password first."
        case .jumpHostRequiresInteractiveAuth(let jumpName):
            "Jump host \"\(jumpName)\" uses interactive 2FA authentication, which cannot run automatically as a ProxyJump hop. Configure an SSH key or saved password on \"\(jumpName)\" instead."
        }
    }
}

/// Builds `[SSHJumpHop]` and `SSHAgentForwardingConfig` from saved `Host` and `KeyStore` state.
enum SSHOptionsBuilder: Sendable {
    /// Non-interactive jump-hop credentials and endpoint snapshot safe to send across actor boundaries.
    struct JumpHopSpec: Sendable {
        let host: String
        let port: UInt16
        let username: String
        let displayName: String
        let auth: SSHAuth

        func makeJumpHop(
            verifyHostKey: @escaping @Sendable (HostKey) async -> HostKeyDecision
        ) -> SSHJumpHop {
            SSHJumpHop(
                host: host,
                port: port,
                username: username,
                auth: auth,
                verifyHostKey: verifyHostKey
            )
        }
    }

    static func displayName(for host: Host) -> String {
        let trimmed = host.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host.hostname : trimmed
    }

    /// Returns `true` when `candidate` can be selected as a ProxyJump bastion for `hostID` without
    /// self-referencing or introducing a cycle according to `ProxyJumpResolver.resolveChain`.
    static func canSelectJumpHost(
        _ candidate: Host,
        forHostID hostID: UUID?,
        allHosts: [Host]
    ) -> Bool {
        if let hostID, candidate.id == hostID {
            return false
        }
        let probe = Host(
            id: hostID ?? UUID(),
            label: "probe",
            hostname: "probe.local",
            proxyJumpHostID: candidate.id
        )
        do {
            _ = try ProxyJumpResolver.resolveChain(for: probe, allHosts: allHosts)
            return true
        } catch ProxyJumpError.cycleDetected {
            return false
        } catch {
            return true
        }
    }

    /// Resolves an OpenSSH `ProxyJump` directive value (alias, hostname, or `user@host:port`)
    /// against newly imported and existing saved `Host` records, returning a non-cyclic `Host.id`.
    static func resolveImportedProxyJump(
        proxyJump rawValue: String,
        for target: Host,
        importedHosts: [Host],
        existingHosts: [Host]
    ) -> UUID? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("none") != .orderedSame else {
            return nil
        }

        // If a multi-hop comma-separated ProxyJump string is provided and doesn't match verbatim,
        // use the immediate (rightmost) hop as the direct ProxyJump target.
        let orderedCandidates = deduplicatedHosts(importedHosts + existingHosts)
        let candidateTokens: [String] = {
            if trimmed.contains(",") {
                let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if let last = parts.last, last != trimmed {
                    return [trimmed, last]
                }
            }
            return [trimmed]
        }()

        for token in candidateTokens {
            let parsed = parseJumpToken(token)
            let pools: [[Host]] = [importedHosts, existingHosts]

            // 1. Prefer exact case-insensitive match on label, then hostname, checking imported hosts first.
            for pool in pools {
                if let matched = matchHost(
                    token: token,
                    parsed: parsed,
                    in: pool,
                    excluding: target.id,
                    target: target,
                    allHosts: orderedCandidates,
                    matchField: .label
                ) {
                    return matched.id
                }
            }
            for pool in pools {
                if let matched = matchHost(
                    token: token,
                    parsed: parsed,
                    in: pool,
                    excluding: target.id,
                    target: target,
                    allHosts: orderedCandidates,
                    matchField: .hostname
                ) {
                    return matched.id
                }
            }
        }

        return nil
    }

    /// Resolves the ordered jump-host chain and builds non-interactive `JumpHopSpec`s.
    static func buildJumpHopSpecs(
        for target: Host,
        allHosts: [Host],
        keyStore: KeyStore = KeyStore(),
        passwordProvider: (UUID) -> String? = { HostSecrets.password(for: $0) }
    ) throws -> [JumpHopSpec] {
        guard target.proxyJumpHostID != nil else { return [] }

        let chain: [Host]
        do {
            chain = try ProxyJumpResolver.resolveChain(for: target, allHosts: allHosts)
        } catch let error as ProxyJumpError {
            switch error {
            case .cycleDetected:
                throw SSHOptionsError.cycleDetected
            case .maxHopsExceeded(let maxHops):
                throw SSHOptionsError.maxHopsExceeded(maxHops)
            case .jumpHostNotFound:
                throw SSHOptionsError.jumpHostNotFound(targetName: displayName(for: target))
            }
        }

        return try chain.map { hop in
            let hopName = displayName(for: hop)
            let trimmedHost = hop.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUser = hop.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty,
                  !trimmedHost.contains(where: \.isWhitespace),
                  !trimmedUser.isEmpty,
                  (1...65535).contains(hop.port) else {
                throw SSHOptionsError.invalidJumpHostEndpoint(jumpName: hopName)
            }

            let auth = try buildNonInteractiveAuth(
                for: hop,
                displayName: hopName,
                keyStore: keyStore,
                passwordProvider: passwordProvider
            )
            return JumpHopSpec(
                host: trimmedHost,
                port: UInt16(hop.port),
                username: trimmedUser,
                displayName: hopName,
                auth: auth
            )
        }
    }

    /// Convenience wrapper building `[SSHJumpHop]` with a per-hop host-key verifier factory.
    static func buildJumpHops(
        for target: Host,
        allHosts: [Host],
        keyStore: KeyStore = KeyStore(),
        passwordProvider: (UUID) -> String? = { HostSecrets.password(for: $0) },
        verifyHostKey: @escaping @Sendable (_ host: String, _ port: Int, _ displayName: String) -> (@Sendable (HostKey) async -> HostKeyDecision)
    ) throws -> [SSHJumpHop] {
        let specs = try buildJumpHopSpecs(
            for: target,
            allHosts: allHosts,
            keyStore: keyStore,
            passwordProvider: passwordProvider
        )
        return specs.map { spec in
            spec.makeJumpHop(
                verifyHostKey: verifyHostKey(spec.host, Int(spec.port), spec.displayName)
            )
        }
    }

    /// Collects usable local signing identities for SSH Agent Forwarding (`-A`) when enabled on `host`.
    static func buildAgentForwardingConfig(
        for host: Host,
        store: KeyStore = KeyStore(),
        overridePassphrases: [UUID: String] = [:]
    ) -> SSHAgentForwardingConfig? {
        guard host.forwardAgent else { return nil }
        let keys = (try? store.list()) ?? []
        let orderedKeys = prioritizeKeys(keys, preferredKeyID: host.keyID)

        var identities: [SSHAgentIdentity] = []
        for key in orderedKeys {
            switch key.type {
            case .secureEnclaveP256:
                guard let signer = try? SecureEnclaveKey.signer(for: key, store: store) else {
                    continue
                }
                identities.append(
                    SSHAgentIdentity(
                        publicKeyBlob: signer.publicKeyBlob,
                        comment: key.name,
                        sign: signer.sign
                    )
                )

            case .ed25519:
                guard let pemData = try? store.privateKey(for: key) else {
                    continue
                }
                let passphrase = overridePassphrases[key.id] ?? (try? store.passphrase(for: key))
                if key.isEncrypted, passphrase == nil {
                    continue
                }
                guard let signingKey = try? OpenSSHEd25519Decoder.decodePrivateKey(
                    from: pemData,
                    passphrase: passphrase
                ) else {
                    continue
                }
                let rawSeed = signingKey.rawRepresentation
                let publicBlob = OpenSSHKeyFormat.publicBlob(ed25519: signingKey.publicKey.rawRepresentation)
                let sign: @Sendable (Data) -> Data? = { data in
                    guard let reloaded = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed) else {
                        return nil
                    }
                    return try? reloaded.signature(for: data)
                }
                identities.append(
                    SSHAgentIdentity(
                        publicKeyBlob: publicBlob,
                        comment: key.name,
                        sign: sign
                    )
                )

            case .ecdsa, .rsa:
                continue
            }
        }

        return SSHAgentForwardingConfig(identities: identities)
    }

    // MARK: Private helpers

    private static func buildNonInteractiveAuth(
        for host: Host,
        displayName: String,
        keyStore: KeyStore,
        passwordProvider: (UUID) -> String?
    ) throws -> SSHAuth {
        switch host.authMethod {
        case "key":
            let keys = (try? keyStore.list()) ?? []
            guard let keyID = host.keyID,
                  let key = keys.first(where: { $0.id == keyID }) else {
                throw SSHOptionsError.jumpHostMissingKey(jumpName: displayName)
            }
            if key.type == .secureEnclaveP256 {
                do {
                    let signer = try SecureEnclaveKey.signer(for: key, store: keyStore)
                    return .signer(publicKeyBlob: signer.publicKeyBlob, sign: signer.sign)
                } catch KeyStoreError.secureEnclaveUnavailable {
                    throw SSHOptionsError.jumpHostSecureEnclaveUnavailable(jumpName: displayName)
                } catch {
                    throw SSHOptionsError.jumpHostMissingKey(jumpName: displayName)
                }
            }
            guard let pem = try? keyStore.privateKey(for: key) else {
                throw SSHOptionsError.jumpHostMissingKey(jumpName: displayName)
            }
            let passphrase = try? keyStore.passphrase(for: key)
            if key.isEncrypted && passphrase == nil {
                throw SSHOptionsError.jumpHostEncryptedKeyNeedsPassphrase(
                    jumpName: displayName,
                    keyName: key.name
                )
            }
            return .privateKey(pem: pem, passphrase: passphrase)

        case "password":
            guard let password = passwordProvider(host.id) else {
                throw SSHOptionsError.jumpHostMissingPassword(jumpName: displayName)
            }
            return .password(password)

        case "keyboardInteractive":
            throw SSHOptionsError.jumpHostRequiresInteractiveAuth(jumpName: displayName)

        default:
            guard let password = passwordProvider(host.id) else {
                throw SSHOptionsError.jumpHostMissingPassword(jumpName: displayName)
            }
            return .password(password)
        }
    }

    private static func prioritizeKeys(_ keys: [StoredKey], preferredKeyID: UUID?) -> [StoredKey] {
        guard let preferredKeyID else { return keys }
        var preferred: [StoredKey] = []
        var others: [StoredKey] = []
        preferred.reserveCapacity(1)
        others.reserveCapacity(keys.count)
        for key in keys {
            if key.id == preferredKeyID {
                preferred.append(key)
            } else {
                others.append(key)
            }
        }
        return preferred + others
    }

    private enum MatchField {
        case label
        case hostname
    }

    private struct ParsedJumpToken {
        let user: String?
        let host: String
        let port: Int?
    }

    private static func deduplicatedHosts(_ hosts: [Host]) -> [Host] {
        var seen = Set<UUID>()
        var result: [Host] = []
        result.reserveCapacity(hosts.count)
        for host in hosts where seen.insert(host.id).inserted {
            result.append(host)
        }
        return result
    }

    private static func matchHost(
        token: String,
        parsed: ParsedJumpToken,
        in pool: [Host],
        excluding excludedID: UUID,
        target: Host,
        allHosts: [Host],
        matchField: MatchField
    ) -> Host? {
        let candidates = pool.filter { candidate in
            guard candidate.id != excludedID else { return false }
            let value: String = switch matchField {
            case .label:
                candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
            case .hostname:
                candidate.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { return false }
            if value.caseInsensitiveCompare(token) == .orderedSame {
                return true
            }
            guard value.caseInsensitiveCompare(parsed.host) == .orderedSame else {
                return false
            }
            if let user = parsed.user, !candidate.username.isEmpty,
               candidate.username != user {
                return false
            }
            if let port = parsed.port, candidate.port != port {
                return false
            }
            return true
        }

        for candidate in candidates where !wouldCreateCycle(target: target, candidate: candidate, allHosts: allHosts) {
            return candidate
        }
        return nil
    }

    private static func wouldCreateCycle(target: Host, candidate: Host, allHosts: [Host]) -> Bool {
        let probe = Host(
            id: target.id,
            label: target.label,
            hostname: target.hostname,
            proxyJumpHostID: candidate.id
        )
        do {
            _ = try ProxyJumpResolver.resolveChain(for: probe, allHosts: allHosts)
            return false
        } catch ProxyJumpError.cycleDetected {
            return true
        } catch {
            return false
        }
    }

    private static func parseJumpToken(_ token: String) -> ParsedJumpToken {
        var user: String?
        var hostPart = token
        if let atIndex = hostPart.lastIndex(of: "@") {
            let userCandidate = String(hostPart[..<atIndex])
            let remainder = String(hostPart[hostPart.index(after: atIndex)...])
            if !userCandidate.isEmpty, !remainder.isEmpty {
                user = userCandidate
                hostPart = remainder
            }
        }

        if hostPart.hasPrefix("["), let closeBracket = hostPart.firstIndex(of: "]") {
            let inner = String(hostPart[hostPart.index(after: hostPart.startIndex)..<closeBracket])
            let after = hostPart[hostPart.index(after: closeBracket)...]
            if after.hasPrefix(":"), let port = Int(after.dropFirst()), (1...65535).contains(port) {
                return ParsedJumpToken(user: user, host: inner, port: port)
            }
            return ParsedJumpToken(user: user, host: inner, port: nil)
        }

        let colonParts = hostPart.split(separator: ":", omittingEmptySubsequences: false)
        if colonParts.count == 2,
           !colonParts[0].isEmpty,
           let port = Int(colonParts[1]),
           (1...65535).contains(port) {
            return ParsedJumpToken(user: user, host: String(colonParts[0]), port: port)
        }

        return ParsedJumpToken(user: user, host: hostPart, port: nil)
    }
}
