import CryptoKit
import Foundation
import SSHKit
import Store
import SwiftData
import XCTest
@testable import TermApp

final class ProxyJumpAndAgentTests: XCTestCase {
    // From OpenSSH `ssh-keygen -t ed25519 -N secret` (aes256-ctr + bcrypt)
    private static let encryptedCTRKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBUsJJQXD
    ux6Ijt2wsssnW0AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHQSKvNocJRNyv9b
    FBGPySnN7UC5wdwymmrGFlHVQQ8KAAAAkBcw/Y8e3z491UVfkfhK9s5mllvrpxQVuaNWnV
    RdxW0CbbWR1JRsOYLUG+IuSPvk6hJmz4lEa9ATwLpwnSMpd7a/Ef9xi+FjudZcho91JP1T
    OUMKdXz+ONQkuvWX0/NkxDzmeU/hIPKA9HIkv0tvMuIrrEfxXPK8+aA9p8JZ39/CBNDDNm
    BO1hEgor+/vV/2tQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    // From OpenSSH `ssh-keygen -t ed25519 -Z aes256-cbc -N secret -C cbc`
    private static let encryptedCBCKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jYmMAAAAGYmNyeXB0AAAAGAAAABBxVXAk/c
    Gw3YrlA6JUngewAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFIXqLXEbfHT1+1y
    BPxZtw+vrdZ+3Q1hBJY+ycVtjPKoAAAAkG0jE7myIVztY1ptXEZqPZ1xMt21nS341Wl3qf
    UPlOB6alR/5Prt2tWcUaWMaGdho+ShLqU6UHThMeVknjaluonW2pgDw6hcxRh+oaWd8fb9
    9l9eKXLCD2Y1aaWYJi4NNcdWr2giXUPgtzGDF9//7Rza5W32K9zqxdeQWQmEYnWBc2etWN
    BcJdPCMjBBLBkLug==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let encryptedCBCPublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXqLXEbfHT1+1yBPxZtw+vrdZ+3Q1hBJY+ycVtjPKo cbc"

    private static let rsaPEMKey = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIBOwIBAAJBALe3oQ==
    -----END RSA PRIVATE KEY-----
    """

    func testDecodeUnencryptedEd25519KeyAndSign() throws {
        let seed = Data((0..<32).map { UInt8($0) })
        let generated = try KeyGenerator.generateEd25519(comment: "unit@test", seed: seed, checkInt: 0x12345678)
        let decoded = try OpenSSHEd25519Decoder.decodePrivateKey(
            from: Data(generated.privateKeyPEM.utf8),
            passphrase: nil
        )
        let expected = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        XCTAssertEqual(decoded.publicKey.rawRepresentation, expected.publicKey.rawRepresentation)

        let payload = Data("ssh-agent-challenge".utf8)
        let signature = try decoded.signature(for: payload)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(expected.publicKey.isValidSignature(signature, for: payload))
    }

    func testDecodeEncryptedEd25519CTRAndCBCKeys() throws {
        let ctrParsed = try OpenSSHKeyFormat.parse(Self.encryptedCTRKey)
        XCTAssertTrue(ctrParsed.isEncrypted)
        XCTAssertThrowsError(
            try OpenSSHEd25519Decoder.decodePrivateKey(from: Self.encryptedCTRKey, passphrase: nil)
        ) { error in
            XCTAssertEqual(error as? OpenSSHEd25519DecoderError, .missingPassphrase)
        }
        XCTAssertThrowsError(
            try OpenSSHEd25519Decoder.decodePrivateKey(from: Self.encryptedCTRKey, passphrase: "wrong")
        ) { error in
            XCTAssertEqual(error as? OpenSSHEd25519DecoderError, .invalidPassphrase)
        }

        let ctrKey = try OpenSSHEd25519Decoder.decodePrivateKey(from: Self.encryptedCTRKey, passphrase: "secret")
        let ctrLine = OpenSSHKeyFormat.ed25519PublicLine(
            publicKey: ctrKey.publicKey.rawRepresentation,
            comment: ""
        )
        XCTAssertEqual(ctrLine, ctrParsed.publicKeyLine)

        let cbcKey = try OpenSSHEd25519Decoder.decodePrivateKey(from: Self.encryptedCBCKey, passphrase: "secret")
        let cbcLine = OpenSSHKeyFormat.ed25519PublicLine(
            publicKey: cbcKey.publicKey.rawRepresentation,
            comment: "cbc"
        )
        XCTAssertEqual(cbcLine, Self.encryptedCBCPublicLine)

        let payload = Data("cbc-challenge".utf8)
        let sig = try cbcKey.signature(for: payload)
        XCTAssertTrue(cbcKey.publicKey.isValidSignature(sig, for: payload))
    }

    func testBuildAgentForwardingConfigCollectsAndPrioritizesKeys() throws {
        let store = KeyStore()
        let plainKey = try KeyGenerator.generateAndStore(
            name: "alpha-plain-\(UUID().uuidString)",
            comment: "plain@test",
            store: store
        )
        let encWithPhrase = try KeyImporter.importKey(
            name: "zeta-enc-\(UUID().uuidString)",
            text: Self.encryptedCTRKey,
            passphrase: "secret",
            savePassphrase: true,
            store: store
        )
        let encWithoutPhrase = try KeyImporter.importKey(
            name: "beta-locked-\(UUID().uuidString)",
            text: Self.encryptedCBCKey,
            passphrase: nil,
            savePassphrase: false,
            store: store
        )
        let rsaKey = StoredKey(
            name: "gamma-rsa-\(UUID().uuidString)",
            type: .rsa,
            publicKey: "ssh-rsa AAAA",
            isEncrypted: false
        )
        try store.add(rsaKey, privateKey: Data(Self.rsaPEMKey.utf8))
        defer {
            try? store.delete(plainKey)
            try? store.delete(encWithPhrase)
            try? store.delete(encWithoutPhrase)
            try? store.delete(rsaKey)
        }

        let disabledHost = Host(label: "no-agent", hostname: "10.0.0.1", keyID: encWithPhrase.id, forwardAgent: false)
        XCTAssertNil(SSHOptionsBuilder.buildAgentForwardingConfig(for: disabledHost, store: store))

        let enabledHost = Host(
            label: "with-agent",
            hostname: "10.0.0.2",
            authMethod: "key",
            keyID: encWithPhrase.id,
            forwardAgent: true
        )
        let config = try XCTUnwrap(SSHOptionsBuilder.buildAgentForwardingConfig(for: enabledHost, store: store))
        // Host's own keyID must appear first; locked encrypted key and RSA key must be skipped.
        let ourIDs = config.identities.filter { $0.comment == encWithPhrase.name || $0.comment == plainKey.name }
        XCTAssertEqual(ourIDs.map(\.comment), [encWithPhrase.name, plainKey.name])
        XCTAssertFalse(config.identities.contains { $0.comment == encWithoutPhrase.name })
        XCTAssertFalse(config.identities.contains { $0.comment == rsaKey.name })

        // Verify signing works and validates against the stored public key.
        let ctrSigningKey = try OpenSSHEd25519Decoder.decodePrivateKey(from: Self.encryptedCTRKey, passphrase: "secret")
        let forwardedIdentity = try XCTUnwrap(config.identities.first)
        XCTAssertEqual(
            forwardedIdentity.publicKeyBlob,
            OpenSSHKeyFormat.publicBlob(ed25519: ctrSigningKey.publicKey.rawRepresentation)
        )
        let challenge = Data("auth-challenge-bytes".utf8)
        let sig = try XCTUnwrap(forwardedIdentity.sign(challenge))
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(ctrSigningKey.publicKey.isValidSignature(sig, for: challenge))
    }

    func testCanSelectJumpHostExcludesSelfAndCycles() {
        let bastion = Host(label: "bastion", hostname: "bastion.example.com")
        let mid = Host(label: "mid", hostname: "10.0.0.2", proxyJumpHostID: bastion.id)
        let app = Host(label: "app", hostname: "10.0.1.5", proxyJumpHostID: mid.id)
        let independent = Host(label: "other", hostname: "10.0.2.5")
        let all = [bastion, mid, app, independent]

        // bastion cannot select itself, nor mid (mid -> bastion), nor app (app -> mid -> bastion).
        XCTAssertFalse(SSHOptionsBuilder.canSelectJumpHost(bastion, forHostID: bastion.id, allHosts: all))
        XCTAssertFalse(SSHOptionsBuilder.canSelectJumpHost(mid, forHostID: bastion.id, allHosts: all))
        XCTAssertFalse(SSHOptionsBuilder.canSelectJumpHost(app, forHostID: bastion.id, allHosts: all))
        XCTAssertTrue(SSHOptionsBuilder.canSelectJumpHost(independent, forHostID: bastion.id, allHosts: all))

        // app can select bastion, mid, or independent, but not itself.
        XCTAssertTrue(SSHOptionsBuilder.canSelectJumpHost(bastion, forHostID: app.id, allHosts: all))
        XCTAssertTrue(SSHOptionsBuilder.canSelectJumpHost(mid, forHostID: app.id, allHosts: all))
        XCTAssertTrue(SSHOptionsBuilder.canSelectJumpHost(independent, forHostID: app.id, allHosts: all))
        XCTAssertFalse(SSHOptionsBuilder.canSelectJumpHost(app, forHostID: app.id, allHosts: all))
    }

    func testResolveImportedProxyJumpMatchesCaseInsensitivelyAndBreaksCycles() {
        let existingBastion = Host(label: "Existing-Edge", hostname: "edge.corp.example", port: 2222, username: "ops")
        let importedMid = Host(label: "MidJump", hostname: "10.10.0.2")
        let importedApp = Host(label: "App", hostname: "10.10.1.9")
        let cycleA = Host(label: "CycleA", hostname: "10.10.2.1")
        let cycleB = Host(label: "CycleB", hostname: "10.10.2.2")
        let imported = [importedMid, importedApp, cycleA, cycleB]
        let existing = [existingBastion]

        // Case-insensitive match on hostname + user@host:port against existing host.
        XCTAssertEqual(
            SSHOptionsBuilder.resolveImportedProxyJump(
                proxyJump: "ops@EDGE.CORP.EXAMPLE:2222",
                for: importedMid,
                importedHosts: imported,
                existingHosts: existing
            ),
            existingBastion.id
        )

        // Case-insensitive match on label against newly imported host.
        XCTAssertEqual(
            SSHOptionsBuilder.resolveImportedProxyJump(
                proxyJump: "midjump",
                for: importedApp,
                importedHosts: imported,
                existingHosts: existing
            ),
            importedMid.id
        )

        // Self-reference is rejected.
        XCTAssertNil(
            SSHOptionsBuilder.resolveImportedProxyJump(
                proxyJump: "App",
                for: importedApp,
                importedHosts: imported,
                existingHosts: existing
            )
        )

        // Mutual cycle: first link succeeds, second link is refused.
        cycleA.proxyJumpHostID = SSHOptionsBuilder.resolveImportedProxyJump(
            proxyJump: "cycleb",
            for: cycleA,
            importedHosts: imported,
            existingHosts: existing
        )
        XCTAssertEqual(cycleA.proxyJumpHostID, cycleB.id)

        cycleB.proxyJumpHostID = SSHOptionsBuilder.resolveImportedProxyJump(
            proxyJump: "cyclea",
            for: cycleB,
            importedHosts: imported,
            existingHosts: existing
        )
        XCTAssertNil(cycleB.proxyJumpHostID)
    }

    func testBuildJumpHopSpecsOrderAndErrorMessages() throws {
        let outer = Host(label: "Outer", hostname: "outer.example.com", port: 2222, username: "jump1", authMethod: "password")
        let inner = Host(label: "Inner", hostname: "10.0.0.2", port: 22, username: "jump2", authMethod: "password", proxyJumpHostID: outer.id)
        let target = Host(label: "Target", hostname: "10.0.1.9", port: 22, username: "app", authMethod: "password", proxyJumpHostID: inner.id)
        let allHosts = [outer, inner, target]

        let passwords = [outer.id: "pw1", inner.id: "pw2"]
        let specs = try SSHOptionsBuilder.buildJumpHopSpecs(
            for: target,
            allHosts: allHosts,
            passwordProvider: { passwords[$0] }
        )
        XCTAssertEqual(specs.map(\.host), ["outer.example.com", "10.0.0.2"])
        XCTAssertEqual(specs.map(\.port), [2222, 22])
        XCTAssertEqual(specs.map(\.username), ["jump1", "jump2"])

        // Missing password on inner jump host throws clear user-friendly LocalizedError.
        XCTAssertThrowsError(
            try SSHOptionsBuilder.buildJumpHopSpecs(
                for: target,
                allHosts: allHosts,
                passwordProvider: { $0 == outer.id ? "pw1" : nil }
            )
        ) { error in
            XCTAssertEqual(error as? SSHOptionsError, .jumpHostMissingPassword(jumpName: "Inner"))
            XCTAssertTrue(error.localizedDescription.contains("Inner"))
        }

        // Interactive 2FA on jump host is rejected clearly.
        let twoFAJump = Host(label: "Bastion2FA", hostname: "2fa.example.com", username: "ops", authMethod: "keyboardInteractive")
        let targetVia2FA = Host(label: "Behind2FA", hostname: "10.0.3.4", username: "ops", proxyJumpHostID: twoFAJump.id)
        XCTAssertThrowsError(
            try SSHOptionsBuilder.buildJumpHopSpecs(for: targetVia2FA, allHosts: [twoFAJump, targetVia2FA])
        ) { error in
            XCTAssertEqual(error as? SSHOptionsError, .jumpHostRequiresInteractiveAuth(jumpName: "Bastion2FA"))
            XCTAssertTrue(error.localizedDescription.contains("Bastion2FA"))
        }

        // Encrypted key without saved passphrase on jump host throws clear error.
        let store = KeyStore()
        let lockedKey = try KeyImporter.importKey(
            name: "locked-jump-key-\(UUID().uuidString)",
            text: Self.encryptedCTRKey,
            passphrase: nil,
            savePassphrase: false,
            store: store
        )
        defer { try? store.delete(lockedKey) }
        let lockedJump = Host(label: "LockedBastion", hostname: "locked.example.com", username: "ops", authMethod: "key", keyID: lockedKey.id)
        let targetViaLocked = Host(label: "BehindLocked", hostname: "10.0.4.5", username: "ops", proxyJumpHostID: lockedJump.id)
        XCTAssertThrowsError(
            try SSHOptionsBuilder.buildJumpHopSpecs(for: targetViaLocked, allHosts: [lockedJump, targetViaLocked], keyStore: store)
        ) { error in
            XCTAssertEqual(
                error as? SSHOptionsError,
                .jumpHostEncryptedKeyNeedsPassphrase(jumpName: "LockedBastion", keyName: lockedKey.name)
            )
            XCTAssertTrue(error.localizedDescription.contains("LockedBastion"))
        }
    }

    @MainActor
    func testAgentHostTargetSnapshotsJumpHopsAndHostConnectionModelSurfacesJumpErrors() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Host.self, configurations: config)
        let context = container.mainContext

        let bastion = Host(label: "Bastion", hostname: "bastion.internal", username: "ops", authMethod: "password")
        let target = Host(label: "Worker", hostname: "10.0.8.8", username: "dev", authMethod: "password", proxyJumpHostID: bastion.id)
        context.insert(bastion)
        context.insert(target)
        try context.save()

        let manager = SessionManager()
        let agentTarget = AgentHostTarget(host: target, sessionManager: manager)
        switch agentTarget.jumpResolution {
        case .success:
            XCTFail("Expected missing jump host password error")
        case .failure(let error):
            XCTAssertTrue(error.isAuthOrTrustIssue)
            XCTAssertTrue((error.errorDescription ?? "").contains("Bastion"))
        }

        // HostConnectionModel surfaces the missing jump host credential error without prompting target password.
        let model = HostConnectionModel(host: target)
        model.start()
        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("Bastion"), "unexpected message: \(message)")
        } else {
            XCTFail("Expected .failed phase when jump host lacks saved password, got \(model.phase)")
        }

        // Now save the bastion password in HostSecrets and verify AgentHostTarget builds the jump hop.
        try HostSecrets.savePassword("bastion-secret", for: bastion.id)
        defer { HostSecrets.deletePassword(for: bastion.id) }

        let readyAgentTarget = AgentHostTarget(host: target, sessionManager: manager)
        switch readyAgentTarget.jumpResolution {
        case .success(let specs):
            XCTAssertEqual(specs.count, 1)
            XCTAssertEqual(specs[0].host, "bastion.internal")
            XCTAssertEqual(specs[0].username, "ops")
        case .failure(let error):
            XCTFail("Expected valid jump hop spec, got error: \(error)")
        }
    }

    func testTrustedOnlyHostKeyVerifier() async throws {
        let service = "com.peculiarengineer.termapp.tests.kh.\(UUID().uuidString)"
        let known = KnownHostsStore(service: service)
        defer { try? known.forget(host: "bastion.test", port: 2222) }

        let key1 = HostKey(type: .ed25519, sha256: Data(repeating: 0xAA, count: 32), keyData: Data([1, 2, 3]))
        let key2 = HostKey(type: .ed25519, sha256: Data(repeating: 0xBB, count: 32), keyData: Data([4, 5, 6]))

        let verifier = AgentAuthHelper.trustedOnlyHostKeyVerifier(host: "bastion.test", port: 2222, knownHosts: known)
        let unknownDecision = await verifier(key1)
        XCTAssertEqual(unknownDecision, .reject)

        try known.trust(host: "bastion.test", port: 2222, fingerprint: key1.fingerprint)
        let matchingDecision = await verifier(key1)
        XCTAssertEqual(matchingDecision, .trust)

        let mismatchDecision = await verifier(key2)
        XCTAssertEqual(mismatchDecision, .reject)
    }
}
