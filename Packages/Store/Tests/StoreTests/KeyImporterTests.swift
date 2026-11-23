import XCTest
@testable import Store

final class KeyImporterTests: XCTestCase {
    func testEd25519() throws {
        let p = try KeyImporter.inspect(try Fixture.text("ed25519.key"))
        XCTAssertEqual(p.type, .ed25519); XCTAssertFalse(p.isEncrypted)
        XCTAssertTrue(p.publicKeyLine?.hasPrefix("ssh-ed25519 ") == true)
        XCTAssertTrue(p.publicKeyLine?.hasSuffix(" fx") == true)
    }

    func testECDSAPEM() throws {
        XCTAssertThrowsError(try KeyImporter.inspect(try Fixture.text("ecdsa.key"))) { error in
            guard case KeyFormatError.unsupported = error else {
                return XCTFail("expected KeyFormatError.unsupported, got \(error)")
            }
        }
    }

    func testRSAPEM() throws {
        let p = try KeyImporter.inspect(try Fixture.text("rsa.key"))
        XCTAssertEqual(p.type, .rsa); XCTAssertFalse(p.isEncrypted)
        XCTAssertTrue(p.publicKeyLine?.hasPrefix("ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB") == true)
    }

    func testRSAOpenSSHComment() throws {
        let p = try KeyImporter.inspect(try Fixture.text("rsa-openssh.key"))
        XCTAssertEqual(p.type, .rsa); XCTAssertFalse(p.isEncrypted)
        XCTAssertEqual(p.comment, "rsa-fixture@test")
        let pub = try Fixture.text("rsa-openssh.pub").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(p.publicKeyLine, pub)
    }

    func testECDSANamedCurvePEM() throws {
        let p = try KeyImporter.inspect(try Fixture.text("ecdsa-named.key"))
        XCTAssertEqual(p.type, .ecdsa); XCTAssertFalse(p.isEncrypted)
        XCTAssertEqual(p.publicKeyLine, "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMg1dHVEkq9RAOqukFn5H/bg1xfEySHfZvHd/FV75QqncAyKw8rg1NYIq2tpAcEx+1m0sYvbodJSdDBpXVYZ+Ns=")  // matches ssh-keygen -y
    }

    func testPassphraseProtected() throws {
        let o = try KeyImporter.inspect(try Fixture.text("ed25519-enc.key"))
        XCTAssertEqual(o.type, .ed25519); XCTAssertTrue(o.isEncrypted)
        XCTAssertNotNil(o.publicKeyLine)
        let r = try KeyImporter.inspect(try Fixture.text("rsa-enc.key"))
        XCTAssertEqual(r.type, .rsa); XCTAssertTrue(r.isEncrypted)
        XCTAssertNil(r.publicKeyLine)
    }

    func testImportStoresAsIsAndKeepsPassphrase() throws {
        let store = KeyStore()
        let text = try Fixture.text("ed25519-enc.key")
        let key = try skippingMissingEntitlement {
            try KeyImporter.importKey(name: "t", text: text, passphrase: "secret", savePassphrase: true, store: store)
        }
        defer { try? store.delete(key) }
        XCTAssertTrue(key.isEncrypted)
        XCTAssertEqual(try store.passphrase(for: key), "secret")
        XCTAssertEqual(try store.privateKey(for: key), Data(text.utf8))
    }
}
