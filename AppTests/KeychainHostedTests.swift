import Foundation
import Security
import XCTest
import SSHKit
import Store
@testable import TermApp

/// Runs inside the app process, so Keychain calls carry the app's entitlement (no -34018 skips).
final class KeychainHostedTests: XCTestCase {
    private let keychain = KeychainStore()
    private let service = "com.peculiarengineer.termapp.hosted.\(UUID().uuidString)"
    private let account = "acct"

    override func tearDown() {
        try? keychain.delete(service: service, account: account)
    }

    /// Whether an item exists with this exact sync value (not SynchronizableAny), so a flip is
    /// verified on the Keychain attribute itself rather than on the data still being readable.
    private func status(service: String, account: String, synced: Bool) -> OSStatus {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synced ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil)
    }

    private func assertOnly(service: String, account: String, synced: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(status(service: service, account: account, synced: synced), errSecSuccess, "expected synced=\(synced) copy", file: file, line: line)
        XCTAssertEqual(status(service: service, account: account, synced: !synced), errSecItemNotFound, "unexpected synced=\(!synced) copy", file: file, line: line)
    }

    func testSaveReadOverwriteDelete() throws {
        XCTAssertNil(try keychain.read(service: service, account: account))
        try keychain.save(Data("one".utf8), service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("one".utf8))
        try keychain.save(Data("two".utf8), service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("two".utf8))
        try keychain.delete(service: service, account: account)
        XCTAssertNil(try keychain.read(service: service, account: account))
        try keychain.delete(service: service, account: account)  // idempotent
    }

    func testSetSynchronizableFlip() throws {
        do {
            try keychain.save(Data("s".utf8), service: service, account: account, synchronizable: true)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            throw XCTSkip("no iCloud account on this simulator (\(e.status))")
        }
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("s".utf8))
        assertOnly(service: service, account: account, synced: true)
        try keychain.setSynchronizable(false, service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("s".utf8))
        assertOnly(service: service, account: account, synced: false)
        try keychain.setSynchronizable(true, service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("s".utf8))
        assertOnly(service: service, account: account, synced: true)
        try keychain.delete(service: service, account: account)
        XCTAssertNil(try keychain.read(service: service, account: account))
    }

    private func saveSynced(_ text: String) throws {
        do {
            try keychain.save(Data(text.utf8), service: service, account: account, synchronizable: true)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            throw XCTSkip("no iCloud account on this simulator (\(e.status))")
        }
    }

    private func addLocalAlongside(_ text: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(text.utf8),
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        XCTAssertEqual(SecItemAdd(attrs as CFDictionary, nil), errSecSuccess)
    }

    func testSetSynchronizableRoundTripLeavesOneItem() throws {
        // local -> synced -> local, through setSynchronizable only.
        try keychain.save(Data("d".utf8), service: service, account: account)
        do {
            try keychain.setSynchronizable(true, service: service, account: account)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            throw XCTSkip("no iCloud Keychain on this simulator (\(e.status))")
        }
        var all = try keychain.readAll(service: service)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.synchronizable, true)
        XCTAssertEqual(all.first?.data, Data("d".utf8))
        try keychain.setSynchronizable(false, service: service, account: account)
        all = try keychain.readAll(service: service)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.synchronizable, false)
        XCTAssertEqual(all.first?.data, Data("d".utf8))
    }

    func testSetSynchronizableToCurrentFlagIsNoOp() throws {
        try keychain.save(Data("x".utf8), service: service, account: account)
        try keychain.setSynchronizable(false, service: service, account: account)
        var all = try keychain.readAll(service: service)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.synchronizable, false)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("x".utf8))
        try saveSynced("x")
        try keychain.setSynchronizable(true, service: service, account: account)
        all = try keychain.readAll(service: service)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.synchronizable, true)
    }

    func testSetSynchronizableMissingItemThrows() {
        XCTAssertThrowsError(try keychain.setSynchronizable(true, service: service, account: account)) {
            XCTAssertEqual(($0 as? KeychainError)?.status, errSecItemNotFound)
        }
    }

    func testReadPrefersSyncedAndSetSynchronizableKeepsIt() throws {
        try saveSynced("synced")
        addLocalAlongside("local")
        XCTAssertEqual(try keychain.readAll(service: service).count, 2)
        XCTAssertEqual(try keychain.read(service: service, account: account), Data("synced".utf8))
        try keychain.setSynchronizable(true, service: service, account: account)
        let all = try keychain.readAll(service: service)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.synchronizable, true)
        XCTAssertEqual(all.first?.data, Data("synced".utf8))
    }

    func testKnownHostsTrustLookupForget() throws {
        let store = KnownHostsStore(service: "com.peculiarengineer.termapp.hosted.kh.\(UUID().uuidString)")
        defer { try? store.forget(host: "example.com", port: 22) }
        XCTAssertNil(try store.fingerprint(host: "Example.com", port: 22))
        try store.trust(host: "Example.com", port: 22, fingerprint: "SHA256:abc")
        XCTAssertEqual(try store.fingerprint(host: "example.com", port: 22), "SHA256:abc")
        XCTAssertNil(try store.fingerprint(host: "example.com", port: 2222))
        try store.forget(host: "example.com", port: 22)
        XCTAssertNil(try store.fingerprint(host: "example.com", port: 22))
    }

    /// Uses the app's real key services with a fresh key ID, and deletes everything it adds.
    /// (A simulator or device signed into an Apple ID may sync the items briefly before the deletes.)
    func testKeyStoreLifecycle() throws {
        let keys = KeyStore()
        let key = StoredKey(name: "hosted-test-\(UUID().uuidString)", type: .ed25519, publicKey: "ssh-ed25519 AAAA test")
        defer { try? keys.delete(key) }
        try keys.add(key, privateKey: Data("private".utf8))
        XCTAssertEqual(try keys.list().filter { $0.id == key.id }.count, 1)
        XCTAssertEqual(try keys.privateKey(for: key), Data("private".utf8))

        do {
            try keys.setSynchronizable(true, for: key)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            throw XCTSkip("no iCloud account on this simulator (\(e.status))")
        }
        let listed = try keys.list().filter { $0.id == key.id }
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.syncsViaICloud, true)
        assertOnly(service: KeyStore.privateService, account: key.id.uuidString, synced: true)
        assertOnly(service: KeyStore.metaService, account: key.id.uuidString, synced: true)

        try keys.delete(key)
        XCTAssertTrue(try keys.list().filter { $0.id == key.id }.isEmpty)
    }

    func testKeyStoreAddDeleteWithoutSync() throws {
        let keys = KeyStore()
        let key = StoredKey(name: "hosted-plain-\(UUID().uuidString)", type: .ed25519, publicKey: "ssh-ed25519 AAAA plain")
        defer { try? keys.delete(key) }
        try keys.add(key, privateKey: Data("p".utf8))
        XCTAssertEqual(try keys.list().filter { $0.id == key.id }.count, 1)
        try keys.delete(key)
        XCTAssertTrue(try keys.list().filter { $0.id == key.id }.isEmpty)
    }

    func testSessionBridgeSecondSubscriberAndFinish() async throws {
        let session = FakeSession()
        let bridge = SessionBridge(session: session)
        let first = bridge.subscribe()
        XCTAssertTrue(first.replay.isEmpty)

        session.emit(Data("hello ".utf8))
        // Wait until the drain task has buffered the first chunk.
        var second = bridge.subscribe()
        for _ in 0..<200 where second.replay.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            second = bridge.subscribe()
        }
        XCTAssertEqual(second.replay, Data("hello ".utf8))

        session.emit(Data("world".utf8))
        var it = second.live.makeAsyncIterator()
        let live = await it.next()
        XCTAssertEqual(live, Data("world".utf8))

        session.finish()
        let end = await it.next()
        XCTAssertNil(end)
        var firstIt = first.live.makeAsyncIterator()
        var drained = Data()
        while let d = await firstIt.next() { drained.append(d) }
        XCTAssertEqual(drained, Data("hello world".utf8))
    }
}

private final class FakeSession: Session, @unchecked Sendable {  // immutable stream + continuation, both thread-safe
    let output: AsyncStream<Data>
    let state: AsyncStream<SessionState>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        state = AsyncStream { _ in }
    }
    func emit(_ d: Data) { continuation.yield(d) }
    func finish() { continuation.finish() }
    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {}
}
