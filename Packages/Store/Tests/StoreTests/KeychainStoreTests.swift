import XCTest
@testable import Store

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore()
    private let service = "com.peculiarengineer.termapp.tests.\(UUID().uuidString)"
    private let account = "acct"

    override func tearDown() {
        try? store.delete(service: service, account: account)
    }

    func testSaveReadDelete() throws {
        try skippingMissingEntitlement { try body1() }
    }

    private func body1() throws {
        _ = try store.read(service: service, account: account)  // probe: throws -34018 when unhosted
        XCTAssertNil(try store.read(service: service, account: account))
        try store.save(Data("one".utf8), service: service, account: account)
        XCTAssertEqual(try store.read(service: service, account: account), Data("one".utf8))
        try store.save(Data("two".utf8), service: service, account: account)
        XCTAssertEqual(try store.read(service: service, account: account), Data("two".utf8))
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.read(service: service, account: account))
        try store.delete(service: service, account: account)  // idempotent
    }

    func testSynchronizableReAddRoundTrip() throws {
        try skippingMissingEntitlement { try body2() }
    }

    private func body2() throws {
        do {
            try store.save(Data("s".utf8), service: service, account: account, synchronizable: true)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            throw XCTSkip("synchronizable items need entitlements (-34018); covered by T10 two-device check")
        }
        XCTAssertEqual(try store.read(service: service, account: account), Data("s".utf8))
        do {
            try store.setSynchronizable(false, service: service, account: account)
            XCTAssertEqual(try store.read(service: service, account: account), Data("s".utf8))
            try store.setSynchronizable(true, service: service, account: account)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            throw XCTSkip("errSecMissingEntitlement")
        }
        XCTAssertEqual(try store.read(service: service, account: account), Data("s".utf8))
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.read(service: service, account: account))
    }

    func testReadAllReturnsSyncFlag() throws {
        try skippingMissingEntitlement {
            try store.save(Data("l".utf8), service: service, account: account)
            let all = try store.readAll(service: service)
            XCTAssertEqual(all.count, 1)
            XCTAssertEqual(all.first?.account, account)
            XCTAssertEqual(all.first?.data, Data("l".utf8))
            XCTAssertEqual(all.first?.synchronizable, false)
        }
    }
}
