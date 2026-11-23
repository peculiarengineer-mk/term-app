import XCTest
@testable import SSHKit

final class AlgorithmPolicyTests: XCTestCase {
    private var lists: [(String, [String])] {
        [("kex", AlgorithmPolicy.kex), ("ciphers", AlgorithmPolicy.ciphers),
         ("macs", AlgorithmPolicy.macs), ("hostKeys", AlgorithmPolicy.hostKeys)]
            .map { ($0.0, $0.1.split(separator: ",").map(String.init)) }
    }

    func testNoDuplicates() {
        for (name, items) in lists { XCTAssertEqual(items.count, Set(items).count, "\(name) has duplicates") }
    }

    func testNoWeakAlgorithms() {
        let substrings = ["sha1", "-cbc", "3des", "arcfour", "blowfish", "cast128", "hmac-md5", "ripemd", "umac-64", "ssh-dss"]
        for (name, items) in lists {
            for item in items {
                for bad in substrings { XCTAssertFalse(item.contains(bad), "\(name) contains \(bad)") }
                XCTAssertNotEqual(item, "ssh-rsa", "\(name) contains ssh-rsa")
            }
        }
    }

    func testPreferenceOrder() {
        XCTAssertTrue(AlgorithmPolicy.kex.hasPrefix("mlkem768x25519-sha256"))
        XCTAssertTrue(AlgorithmPolicy.ciphers.hasPrefix("chacha20-poly1305@openssh.com"))
    }

    func testIsPostQuantum() {
        func n(_ kex: String) -> NegotiatedAlgorithms { .init(kex: kex, hostKey: "", cipher: "", mac: "") }
        XCTAssertTrue(n("mlkem768x25519-sha256").isPostQuantum)
        XCTAssertTrue(n("sntrup761x25519-sha512").isPostQuantum)
        XCTAssertFalse(n("curve25519-sha256").isPostQuantum)
    }

    /// Offline: every policy name is implemented by the linked libssh2 (catches a rebuild that lost ML-KEM).
    func testLinkedLibrarySupportsWholePolicy() {
        XCTAssertEqual(AlgorithmPolicy.unsupportedNames(), [])
    }
}
