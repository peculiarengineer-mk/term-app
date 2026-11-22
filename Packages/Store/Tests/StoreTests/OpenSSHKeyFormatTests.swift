import XCTest
import CryptoKit
@testable import Store

enum Fixture {
    static func text(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class OpenSSHKeyFormatTests: XCTestCase {
    func testGeneratedKeyParsesBackToSamePublicKey() throws {
        let g = try KeyGenerator.generateEd25519(comment: "me@host")
        let p = try OpenSSHKeyFormat.parse(g.privateKeyPEM)
        XCTAssertEqual(p.type, .ed25519)
        XCTAssertFalse(p.isEncrypted)
        XCTAssertEqual(p.publicKeyLine, g.publicLine)
        XCTAssertTrue(g.publicLine.hasPrefix("ssh-ed25519 AAAA"))
    }

    func testFixedSeedMatchesFixture() throws {
        let seed = Data((0..<32).map { UInt8($0) })
        let g = try KeyGenerator.generateEd25519(comment: "fixed", seed: seed, checkInt: 0xDEADBEEF)
        XCTAssertEqual(g.privateKeyPEM, try Fixture.text("ed25519-fixed.key"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHKeyFormat.parse("hello"))
        XCTAssertThrowsError(try OpenSSHKeyFormat.parse("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"))
    }
}
