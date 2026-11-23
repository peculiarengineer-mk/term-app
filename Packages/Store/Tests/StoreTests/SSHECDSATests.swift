import XCTest
import CryptoKit
@testable import Store

final class SSHECDSATests: XCTestCase {
    func testPublicBlobParses() throws {
        let k = P256.Signing.PrivateKey()
        let blob = SSHECDSA.publicKeyBlob(x963: k.publicKey.x963Representation)
        var r = OpenSSHKeyFormat.Reader(data: blob, pos: 0)
        XCTAssertEqual(String(decoding: try r.string(), as: UTF8.self), "ecdsa-sha2-nistp256")
        XCTAssertEqual(String(decoding: try r.string(), as: UTF8.self), "nistp256")
        let point = try r.string()
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(point.first, 0x04)
        XCTAssertEqual(r.pos, blob.count)
        XCTAssertTrue(SSHECDSA.publicLine(x963: point, comment: "c").hasPrefix("ecdsa-sha2-nistp256 "))
    }

    func testRoundTrip() throws {
        for _ in 0..<50 {
            let raw = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            XCTAssertEqual(try SSHECDSA.rawRS(fromSignatureBlob: SSHECDSA.signatureBlob(rawRS: raw)), raw)
        }
    }

    func testMpintVectors() throws {
        var raw = Data(repeating: 0, count: 64)
        raw[0] = 0x80; raw[31] = 1      // r: top bit set
        raw[32] = 0; raw[33] = 0; raw[34] = 0x7F; raw[63] = 2  // s: leading zeros
        let blob = SSHECDSA.signatureBlob(rawRS: raw)
        var r = OpenSSHKeyFormat.Reader(data: blob, pos: 0)
        let rr = try r.string(), ss = try r.string()
        XCTAssertEqual(rr.count, 33); XCTAssertEqual(rr.first, 0x00); XCTAssertEqual(rr[rr.startIndex + 1], 0x80)
        XCTAssertEqual(ss.count, 30); XCTAssertEqual(ss.first, 0x7F)
        let zero = SSHECDSA.signatureBlob(rawRS: Data(repeating: 0, count: 64))
        XCTAssertEqual(zero, Data(repeating: 0, count: 8))
    }

    func testSignatureVerifies() throws {
        let k = P256.Signing.PrivateKey()
        let msg = Data("fixed bytes".utf8)
        let sig = try k.signature(for: msg)
        let raw = try SSHECDSA.rawRS(fromSignatureBlob: SSHECDSA.signatureBlob(rawRS: sig.rawRepresentation))
        XCTAssertTrue(k.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: msg))
    }

    func testEnclaveKeyCannotSync() throws {
        let store = KeyStore()
        let key = StoredKey(name: "se", type: .secureEnclaveP256, publicKey: "", syncsViaICloud: true)
        // These return before any Keychain write, so they run even without a Keychain entitlement.
        XCTAssertThrowsError(try store.setSynchronizable(true, for: key)) {
            XCTAssertEqual($0 as? KeyStoreError, .secureEnclaveKeyCannotSync)
        }
        XCTAssertNoThrow(try store.setSynchronizable(false, for: key))
        try skippingMissingEntitlement {
            try store.add(key, privateKey: Data([1, 2, 3]))
            defer { try? store.delete(key) }
            XCTAssertEqual(try store.list().first { $0.id == key.id }?.syncsViaICloud, false)
            // A stale snapshot with another type must not sync the stored enclave key.
            var stale = key; stale.type = .ed25519
            XCTAssertThrowsError(try store.setSynchronizable(true, for: stale)) {
                XCTAssertEqual($0 as? KeyStoreError, .secureEnclaveKeyCannotSync)
            }
        }
    }

    func testEnclaveSignatureVerifies() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave")
        let created = try SecureEnclave.P256.Signing.PrivateKey()
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: created.dataRepresentation)
        let msg = Data("session id and userauth request".utf8)
        let blob = SSHECDSA.signatureBlob(rawRS: try key.signature(for: msg).rawRepresentation)
        let raw = try SSHECDSA.rawRS(fromSignatureBlob: blob)
        let pub = try P256.Signing.PublicKey(x963Representation: key.publicKey.x963Representation)
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: msg))
    }

    func testGenerateUnavailableOnSimulator() throws {
        try XCTSkipIf(SecureEnclaveKey.isAvailable, "device has a Secure Enclave")
        XCTAssertThrowsError(try SecureEnclaveKey.generateAndStore(name: "n", comment: "c", store: KeyStore())) {
            XCTAssertEqual($0 as? KeyStoreError, .secureEnclaveUnavailable)
        }
    }

    func testRawRSRejectsNegativeAndNonCanonicalMpints() throws {
        func sigBlob(_ r: [UInt8], _ s: [UInt8]) -> Data {
            var w = OpenSSHKeyFormat.Writer()
            w.string(Data(r))
            w.string(Data(s))
            return w.data
        }
        func assertMalformed(_ r: [UInt8], _ s: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try SSHECDSA.rawRS(fromSignatureBlob: sigBlob(r, s)), file: file, line: line) { error in
                guard case KeyFormatError.malformed = error else {
                    XCTFail("expected KeyFormatError.malformed, got \(error)", file: file, line: line)
                    return
                }
            }
        }

        // Negative mpints (high bit set in first byte)
        assertMalformed([0x80], [0x01])
        assertMalformed([0x01], [0xFF, 0x01])

        // Non-canonical leading 0x00 padding
        assertMalformed([0x00], [0x01])
        assertMalformed([0x01], [0x00])
        assertMalformed([0x00, 0x7F], [0x01])
        assertMalformed([0x01], [0x00, 0x7F])
        assertMalformed([0x00, 0x00, 0x80], [0x01])

        // Canonical 0x00 prefix (next byte has MSB set) and zero (empty) must succeed
        let raw = try SSHECDSA.rawRS(fromSignatureBlob: sigBlob([0x00, 0x80], []))
        XCTAssertEqual(raw, Data([UInt8](repeating: 0, count: 31) + [0x80] + [UInt8](repeating: 0, count: 32)))
    }

    func testSetSynchronizableMissingMetadataThrowsKeyMissing() throws {
        let mock = MockKeychainStorage()
        let mockStore = KeyStore(storage: mock)
        let missing = StoredKey(name: "missing", type: .ed25519, publicKey: "ssh-ed25519 AAAA")
        XCTAssertThrowsError(try mockStore.setSynchronizable(true, for: missing)) {
            XCTAssertEqual($0 as? KeyStoreError, .keyMissing)
        }
        XCTAssertThrowsError(try mockStore.setSynchronizable(false, for: missing)) {
            XCTAssertEqual($0 as? KeyStoreError, .keyMissing)
        }
    }

    func testSetSynchronizableRealStoreMissingMetadataThrowsKeyMissing() throws {
        let missing = StoredKey(name: "missing", type: .ed25519, publicKey: "ssh-ed25519 AAAA")
        try skippingMissingEntitlement {
            let store = KeyStore()
            do {
                try store.setSynchronizable(true, for: missing)
                XCTFail("expected KeyStoreError.keyMissing")
            } catch let e as KeyStoreError {
                XCTAssertEqual(e, .keyMissing)
            }
        }
    }

    func testSetSynchronizableRollsBackOnPartialFailure() throws {
        let mock = MockKeychainStorage()
        let store = KeyStore(storage: mock)
        let key = StoredKey(name: "k", type: .ed25519, publicKey: "ssh-ed25519 AAAA", isEncrypted: true, syncsViaICloud: false)
        let acct = key.id.uuidString
        try store.add(key, privateKey: Data("priv".utf8), passphrase: "secret")

        // 1. Failure while flipping passphraseService rolls back privateService.
        mock.failSetSyncService = KeyStore.passphraseService
        XCTAssertThrowsError(try store.setSynchronizable(true, for: key)) {
            XCTAssertEqual($0 as? KeychainError, KeychainError(status: errSecIO))
        }
        XCTAssertEqual(mock.syncFlag(service: KeyStore.privateService, account: acct), false)
        XCTAssertEqual(mock.syncFlag(service: KeyStore.passphraseService, account: acct), false)
        XCTAssertEqual(try store.list().first?.syncsViaICloud, false)

        // 2. Failure while saving metaService rolls back both privateService and passphraseService.
        mock.failSetSyncService = nil
        mock.failSaveService = KeyStore.metaService
        XCTAssertThrowsError(try store.setSynchronizable(true, for: key)) {
            XCTAssertEqual($0 as? KeychainError, KeychainError(status: errSecIO))
        }
        XCTAssertEqual(mock.syncFlag(service: KeyStore.privateService, account: acct), false)
        XCTAssertEqual(mock.syncFlag(service: KeyStore.passphraseService, account: acct), false)
        XCTAssertEqual(mock.syncFlag(service: KeyStore.metaService, account: acct), false)
        XCTAssertEqual(try store.list().first?.syncsViaICloud, false)

        // 3. Flip to true succeeds cleanly, and failure flipping back to false rolls back to true.
        mock.failSaveService = nil
        try store.setSynchronizable(true, for: key)
        XCTAssertEqual(try store.list().first?.syncsViaICloud, true)
        mock.failSaveService = KeyStore.metaService
        XCTAssertThrowsError(try store.setSynchronizable(false, for: key))
        XCTAssertEqual(mock.syncFlag(service: KeyStore.privateService, account: acct), true)
        XCTAssertEqual(mock.syncFlag(service: KeyStore.passphraseService, account: acct), true)
        XCTAssertEqual(mock.syncFlag(service: KeyStore.metaService, account: acct), true)
        XCTAssertEqual(try store.list().first?.syncsViaICloud, true)
    }
}

private final class MockKeychainStorage: KeychainStoring, @unchecked Sendable {
    private struct ItemKey: Hashable {
        let service: String
        let account: String
        let synchronizable: Bool
    }
    private var items: [ItemKey: Data] = [:]
    var failSetSyncService: String?
    var failSaveService: String?

    func syncFlag(service: String, account: String) -> Bool? {
        if items[ItemKey(service: service, account: account, synchronizable: true)] != nil { return true }
        if items[ItemKey(service: service, account: account, synchronizable: false)] != nil { return false }
        return nil
    }

    func save(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        if service == failSaveService { throw KeychainError(status: errSecIO) }
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)] = data
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: !synchronizable))
    }

    func read(service: String, account: String) throws -> Data? {
        if let synced = try read(service: service, account: account, synchronizable: true) { return synced }
        return try read(service: service, account: account, synchronizable: false)
    }

    func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)]
    }

    func readAll(service: String) throws -> [(account: String, data: Data, synchronizable: Bool)] {
        items.compactMap { key, data in
            key.service == service ? (key.account, data, key.synchronizable) : nil
        }
    }

    func delete(service: String, account: String) throws {
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: true))
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: false))
    }

    func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws {
        if service == failSetSyncService { throw KeychainError(status: errSecIO) }
        guard let data = try read(service: service, account: account, synchronizable: !synchronizable) else {
            if try read(service: service, account: account, synchronizable: synchronizable) != nil { return }
            throw KeychainError(status: errSecItemNotFound)
        }
        if items[ItemKey(service: service, account: account, synchronizable: synchronizable)] == nil {
            items[ItemKey(service: service, account: account, synchronizable: synchronizable)] = data
        }
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: !synchronizable))
    }
}
