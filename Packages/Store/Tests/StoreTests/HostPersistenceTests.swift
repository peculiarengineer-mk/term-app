import XCTest
import SwiftData
@testable import Store

final class HostPersistenceTests: XCTestCase {
    func testHostsPersistAcrossRecreatedContainer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.store")
        let keyID = UUID()
        let hostID: UUID

        do {
            let container = try ModelContainer(
                for: Host.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let h = Host(label: "box", hostname: "example.com", port: 2222, username: "me",
                         authMethod: "key", keyID: keyID, tmuxCommand: "tmux a", tags: ["a", "b"])
            hostID = h.id
            context.insert(h)
            try context.save()
        }

        let container = try ModelContainer(
            for: Host.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let hosts = try ModelContext(container).fetch(FetchDescriptor<Host>())
        XCTAssertEqual(hosts.count, 1)
        let h = try XCTUnwrap(hosts.first)
        XCTAssertEqual(h.id, hostID)
        XCTAssertEqual(h.hostname, "example.com")
        XCTAssertEqual(h.port, 2222)
        XCTAssertEqual(h.authMethod, "key")
        XCTAssertEqual(h.keyID, keyID)
        XCTAssertEqual(h.tmuxCommand, "tmux a")
        XCTAssertEqual(h.tags, ["a", "b"])
        XCTAssertEqual(h.source, "manual")
    }

    func testTouchMovesUpdatedAtKeepsCopyID() {
        let old = Date(timeIntervalSince1970: 0)
        let h = Host(createdAt: old, updatedAt: old)
        let copy = h.copyID
        h.touch()
        XCTAssertGreaterThan(h.updatedAt, old)
        XCTAssertEqual(h.createdAt, old)
        XCTAssertEqual(h.copyID, copy)
    }

    func testInsertedHostsGetDistinctCopyIDs() throws {
        let container = try ModelContainer(
            for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let a = Host(), b = Host()
        context.insert(a); context.insert(b)
        try context.save()
        XCTAssertNotEqual(a.copyID, b.copyID)
    }
}
