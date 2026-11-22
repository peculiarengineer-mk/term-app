import XCTest
@testable import Store

final class KnownHostsStoreTests: XCTestCase {
    func testTrustLookupForget() throws {
        try skippingMissingEntitlement { try body() }
    }

    private func body() throws {
        let store = KnownHostsStore(service: "com.peculiarengineer.termapp.tests.kh.\(UUID().uuidString)")
        _ = try store.fingerprint(host: "Example.com", port: 22)  // probe: throws -34018 when unhosted
        XCTAssertNil(try store.fingerprint(host: "Example.com", port: 22))
        try store.trust(host: "Example.com", port: 22, fingerprint: "SHA256:abc")
        XCTAssertEqual(try store.fingerprint(host: "example.com", port: 22), "SHA256:abc")
        XCTAssertNil(try store.fingerprint(host: "example.com", port: 2222))
        try store.trust(host: "example.com", port: 22, fingerprint: "SHA256:def")
        XCTAssertEqual(try store.fingerprint(host: "example.com", port: 22), "SHA256:def")
        try store.forget(host: "example.com", port: 22)
        XCTAssertNil(try store.fingerprint(host: "example.com", port: 22))
    }

    func testTrustLocalRoundTrip() throws {
        try skippingMissingEntitlement {
            let service = "com.peculiarengineer.termapp.tests.kh.\(UUID().uuidString)"
            let store = KnownHostsStore(service: service)
            _ = try store.fingerprint(host: "h", port: 22)  // probe
            defer { try? store.forget(host: "h", port: 22) }
            try store.trust(host: "h", port: 22, fingerprint: "SHA256:loc", synchronizable: false)
            XCTAssertEqual(try store.fingerprint(host: "h", port: 22), "SHA256:loc")
            XCTAssertEqual(try KeychainStore().readAll(service: service).map(\.synchronizable), [false])
        }
    }
}
