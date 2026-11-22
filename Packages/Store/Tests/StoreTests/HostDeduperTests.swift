import XCTest
import SwiftData
@testable import Store

final class HostDeduperTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Host.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private let c1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let c2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testThreeCopiesCollapseToLowestCopyIDWithNewestFields() throws {
        let context = try makeContext()
        let id = UUID()
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        context.insert(Host(id: id, label: "mid", updatedAt: t.addingTimeInterval(-50), copyID: c3))
        context.insert(Host(id: id, label: "old", updatedAt: t.addingTimeInterval(-100), copyID: c1))
        context.insert(Host(id: id, label: "new", updatedAt: t, copyID: c2))
        try context.save()

        XCTAssertEqual(try HostDeduper.dedupe(in: context), 2)
        let hosts = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].copyID, c1)
        XCTAssertEqual(hosts[0].label, "new")
        XCTAssertEqual(hosts[0].updatedAt, t)
    }

    func testSameMillisecondCountsAsEqual() throws {
        let context = try makeContext()
        let id = UUID()
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        context.insert(Host(id: id, label: "survivor", updatedAt: t, copyID: c1))
        context.insert(Host(id: id, label: "other", updatedAt: t.addingTimeInterval(0.0004), copyID: c2))
        try context.save()

        XCTAssertEqual(try HostDeduper.dedupe(in: context), 1)
        let hosts = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].copyID, c1)
        XCTAssertEqual(hosts[0].label, "survivor")
        XCTAssertEqual(hosts[0].updatedAt, t)
    }

    func testNewerCopiesInSameMillisecondUseLowerCopyID() throws {
        let context = try makeContext()
        let id = UUID()
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let newer = t.addingTimeInterval(10)
        context.insert(Host(id: id, label: "survivor", updatedAt: t, copyID: c1))
        context.insert(Host(id: id, label: "from-c3", updatedAt: newer.addingTimeInterval(0.0002), copyID: c3))
        context.insert(Host(id: id, label: "from-c2", updatedAt: newer, copyID: c2))
        try context.save()

        XCTAssertEqual(try HostDeduper.dedupe(in: context), 2)
        let hosts = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].copyID, c1)
        XCTAssertEqual(hosts[0].label, "from-c2")
        XCTAssertEqual(hosts[0].updatedAt, newer)
    }

    func testDistinctIDsAreUntouched() throws {
        let context = try makeContext()
        context.insert(Host(label: "one", copyID: c1))
        context.insert(Host(label: "two", copyID: c2))
        try context.save()
        XCTAssertEqual(try HostDeduper.dedupe(in: context), 0)
        let hosts = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(Set(hosts.map(\.label)), ["one", "two"])
        XCTAssertEqual(Set(hosts.map(\.copyID)), [c1, c2])
    }

    func testSecondRunDeletesNothingAndChangesNothing() throws {
        let context = try makeContext()
        let id = UUID()
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        context.insert(Host(id: id, label: "old", updatedAt: t, copyID: c1))
        context.insert(Host(id: id, label: "new", hostname: "h", port: 2222, tags: ["a"], updatedAt: t.addingTimeInterval(5), copyID: c2))
        try context.save()

        XCTAssertEqual(try HostDeduper.dedupe(in: context), 1)
        let first = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(first.count, 1)
        let snap = (first[0].label, first[0].hostname, first[0].port, first[0].tags, first[0].updatedAt, first[0].createdAt, first[0].copyID)

        XCTAssertEqual(try HostDeduper.dedupe(in: context), 0)
        let second = try context.fetch(FetchDescriptor<Host>())
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].label, snap.0)
        XCTAssertEqual(second[0].hostname, snap.1)
        XCTAssertEqual(second[0].port, snap.2)
        XCTAssertEqual(second[0].tags, snap.3)
        XCTAssertEqual(second[0].updatedAt, snap.4)
        XCTAssertEqual(second[0].createdAt, snap.5)
        XCTAssertEqual(second[0].copyID, snap.6)
    }
}
