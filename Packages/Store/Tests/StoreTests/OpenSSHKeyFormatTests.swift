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

    func testRejectsMissingOrMismatchedEndFooter() throws {
        let g = try KeyGenerator.generateEd25519(comment: "me@host")
        let noEndOpenSSH = g.privateKeyPEM.replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
        assertMalformed(try OpenSSHKeyFormat.parse(noEndOpenSSH))

        let mismatchedOpenSSH = g.privateKeyPEM.replacingOccurrences(
            of: "-----END OPENSSH PRIVATE KEY-----",
            with: "-----END RSA PRIVATE KEY-----"
        )
        assertMalformed(try OpenSSHKeyFormat.parse(mismatchedOpenSSH))

        let rsaPEM = try Fixture.text("rsa.key")
        let noEndRSA = rsaPEM.replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
        assertMalformed(try OpenSSHKeyFormat.parse(noEndRSA))

        let rsaEncPEM = try Fixture.text("rsa-enc.key")
        let noEndRSAEnc = rsaEncPEM.replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
        assertMalformed(try OpenSSHKeyFormat.parse(noEndRSAEnc))
    }

    func testRejectsEncryptedPEMWithoutValidBody() {
        let emptyEncrypted = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,AA573708555CB617D062BCEA53A4A85F

        -----END RSA PRIVATE KEY-----
        """
        assertMalformed(try OpenSSHKeyFormat.parse(emptyEncrypted))

        let badB64Encrypted = """
        -----BEGIN EC PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,AA573708555CB617D062BCEA53A4A85F

        not!valid!base64!
        -----END EC PRIVATE KEY-----
        """
        assertMalformed(try OpenSSHKeyFormat.parse(badB64Encrypted))
    }

    func testRejectsTruncatedEncryptedOpenSSHKey() {
        let pubBlob = OpenSSHKeyFormat.publicBlob(ed25519: Data(repeating: 0x11, count: 32))
        var missingPriv = OpenSSHKeyFormat.Writer()
        missingPriv.data = Data("openssh-key-v1\0".utf8)
        missingPriv.string(Data("aes256-ctr".utf8))
        missingPriv.string(Data("bcrypt".utf8))
        missingPriv.string(Data())
        missingPriv.uint32(1)
        missingPriv.string(pubBlob)
        assertMalformed(try OpenSSHKeyFormat.parse(armorOpenSSH(missingPriv.data)))

        var truncatedPriv = missingPriv
        truncatedPriv.uint32(32)
        truncatedPriv.data.append(contentsOf: [1, 2, 3, 4])
        assertMalformed(try OpenSSHKeyFormat.parse(armorOpenSSH(truncatedPriv.data)))

        var emptyPriv = missingPriv
        emptyPriv.string(Data())
        assertMalformed(try OpenSSHKeyFormat.parse(armorOpenSSH(emptyPriv.data)))
    }

    func testRejectsECDSACertificateAsUnsupported() throws {
        for alg in ["ecdsa-sha2-nistp256-cert-v01@openssh.com", "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-secp256k1"] {
            var pubBlob = OpenSSHKeyFormat.Writer()
            pubBlob.string(Data(alg.utf8))
            pubBlob.string(Data("nistp256".utf8))
            pubBlob.string(Data([0x04] + [UInt8](repeating: 0x22, count: 64)))

            var w = OpenSSHKeyFormat.Writer()
            w.data = Data("openssh-key-v1\0".utf8)
            w.string(Data("aes256-ctr".utf8))
            w.string(Data("bcrypt".utf8))
            w.string(Data())
            w.uint32(1)
            w.string(pubBlob.data)
            w.string(Data(repeating: 0xAA, count: 32))

            XCTAssertThrowsError(try OpenSSHKeyFormat.parse(armorOpenSSH(w.data))) { error in
                guard case KeyFormatError.unsupported = error else {
                    return XCTFail("expected KeyFormatError.unsupported for \(alg), got \(error)")
                }
            }
        }
    }

    func testRejectsExplicitParameterECKeyAndInvalidECPoint() throws {
        XCTAssertThrowsError(try OpenSSHKeyFormat.parse(try Fixture.text("ecdsa.key"))) { error in
            guard case KeyFormatError.unsupported = error else {
                return XCTFail("expected KeyFormatError.unsupported, got \(error)")
            }
        }

        // Build EC PEM with named nistp256 OID but invalid unused-bits byte (0x01) or non-0x04 point tag (0x02).
        let oid = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let badUnusedBitsPoint = Data([0x01, 0x04] + [UInt8](repeating: 0x11, count: 64))
        assertMalformed(try OpenSSHKeyFormat.parse(ecPEM(params: oid, bitStringPayload: badUnusedBitsPoint)))

        let compressedPoint = Data([0x00, 0x02] + [UInt8](repeating: 0x11, count: 64))
        assertMalformed(try OpenSSHKeyFormat.parse(ecPEM(params: oid, bitStringPayload: compressedPoint)))
    }

    func testPublicLineSanitizesNewlinesInComment() throws {
        let blob = Data([1, 2, 3])
        let injected = OpenSSHKeyFormat.publicLine(blob: blob, type: "ssh-ed25519", comment: "me@host\nssh-ed25519 AAAA evil\r\nsecond")
        XCTAssertFalse(injected.contains("\n"))
        XCTAssertFalse(injected.contains("\r"))
        XCTAssertEqual(injected, "ssh-ed25519 AQID me@host ssh-ed25519 AAAA evil second")

        let onlyNewlines = OpenSSHKeyFormat.publicLine(blob: blob, type: "ssh-ed25519", comment: "\r\n\n")
        XCTAssertEqual(onlyNewlines, "ssh-ed25519 AQID")

        let generated = try KeyGenerator.generateEd25519(comment: "user@host\r\nssh-rsa AAAA")
        XCTAssertFalse(generated.publicLine.contains("\n"))
        XCTAssertFalse(generated.publicLine.contains("\r"))
        let parsed = try OpenSSHKeyFormat.parse(generated.privateKeyPEM)
        XCTAssertFalse(try XCTUnwrap(parsed.publicKeyLine).contains("\n"))
        XCTAssertFalse(try XCTUnwrap(parsed.publicKeyLine).contains("\r"))
    }

    private func assertMalformed<T>(_ expr: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { error in
            guard case KeyFormatError.malformed = error else {
                XCTFail("expected KeyFormatError.malformed, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func armorOpenSSH(_ data: Data) -> String {
        "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var d = Data([tag])
        if content.count < 0x80 {
            d.append(UInt8(content.count))
        } else {
            d.append(0x81)
            d.append(UInt8(content.count))
        }
        d.append(content)
        return d
    }

    private func ecPEM(params: Data, bitStringPayload: Data) -> String {
        let version = tlv(0x02, Data([0x01]))
        let priv = tlv(0x04, Data(repeating: 0x22, count: 32))
        let pWrap = tlv(0xA0, params)
        let pubWrap = tlv(0xA1, tlv(0x03, bitStringPayload))
        let seq = tlv(0x30, version + priv + pWrap + pubWrap)
        return "-----BEGIN EC PRIVATE KEY-----\n\(seq.base64EncodedString())\n-----END EC PRIVATE KEY-----\n"
    }
}
