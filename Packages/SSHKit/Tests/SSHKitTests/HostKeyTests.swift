import XCTest
import Foundation
@testable import SSHKit

final class HostKeyTests: XCTestCase {
    func testFingerprintKnownVectorsAndNoPadding() {
        let zeros = HostKey(type: .ed25519, sha256: Data(repeating: 0, count: 32), keyData: Data())
        XCTAssertEqual(zeros.fingerprint, "SHA256:" + String(repeating: "A", count: 43))
        XCTAssertFalse(zeros.fingerprint.hasSuffix("="))

        let seq = HostKey(type: .rsa, sha256: Data(0..<32), keyData: Data())
        XCTAssertEqual(seq.fingerprint, "SHA256:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertFalse(seq.fingerprint.hasSuffix("="))

        // Lengths producing 0, 1, and 2 '=' padding characters in base64.
        for count in [30, 31, 32] {
            let key = HostKey(type: .ecdsaP256, sha256: Data(repeating: 0x5A, count: count), keyData: Data())
            XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
            XCTAssertFalse(key.fingerprint.contains("="))
        }
    }

    func testHostKeyTypeLibssh2Mapping() {
        XCTAssertEqual(HostKeyType(libssh2: 0), .unknown)
        XCTAssertEqual(HostKeyType(libssh2: 1), .rsa)
        XCTAssertEqual(HostKeyType(libssh2: 2), .dss)
        XCTAssertEqual(HostKeyType(libssh2: 3), .ecdsaP256)
        XCTAssertEqual(HostKeyType(libssh2: 4), .ecdsaP384)
        XCTAssertEqual(HostKeyType(libssh2: 5), .ecdsaP521)
        XCTAssertEqual(HostKeyType(libssh2: 6), .ed25519)
        XCTAssertEqual(HostKeyType(libssh2: -1), .unknown)
        XCTAssertEqual(HostKeyType(libssh2: 99), .unknown)

        XCTAssertEqual(HostKeyType.ed25519.rawValue, "ssh-ed25519")
        XCTAssertEqual(HostKeyType.ecdsaP256.rawValue, "ecdsa-sha2-nistp256")
        XCTAssertEqual(HostKeyType.rsa.rawValue, "ssh-rsa")
    }
}
