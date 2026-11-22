import XCTest
import Store
@testable import TermApp

final class KeyStorePassphraseTests: XCTestCase {
    func testSavePassphraseForLocalKeyStaysLocal() throws {
        let store = KeyStore()
        let key = StoredKey(name: "pp-test", type: .ed25519, publicKey: "", isEncrypted: true, syncsViaICloud: false)
        try store.add(key, privateKey: Data("pem".utf8))
        defer { try? store.delete(key) }
        try store.savePassphrase("hunter2", for: key)
        XCTAssertEqual(try store.passphrase(for: key), "hunter2")
        let items = try KeychainStore().readAll(service: KeyStore.passphraseService)
        let item = items.first { $0.account == key.id.uuidString }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.synchronizable, false)
    }
}
