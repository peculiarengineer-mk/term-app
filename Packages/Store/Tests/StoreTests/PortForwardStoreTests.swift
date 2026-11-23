import XCTest
@testable import Store

final class PortForwardStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "termapp.tests.forwards.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testInitialEmptyStateAndCorruptPayloadFallback() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [])
        XCTAssertEqual(PortForwardStore.list(for: hostID, defaults: defaults), [])

        defaults.set(Data("not-json".utf8), forKey: PortForwardStore.storageKey)
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [])
        XCTAssertEqual(PortForwardStore.list(for: hostID, defaults: defaults), [])
    }

    func testUpsertInsertsAndUpdatesInPlace() throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        let first = SavedPortForward(
            hostID: hostID,
            name: "Postgres",
            localPort: 5432,
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            autoStart: true
        )
        let second = SavedPortForward(
            hostID: hostID,
            name: "Web",
            localPort: 0,
            remoteHost: "10.0.0.5",
            remotePort: 8080,
            autoStart: false
        )
        let third = SavedPortForward(
            hostID: hostID,
            localPort: 6379,
            remotePort: 6379
        )

        PortForwardStore.upsert(first, defaults: defaults)
        PortForwardStore.upsert(second, defaults: defaults)
        PortForwardStore.upsert(third, defaults: defaults)

        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [first, second, third])

        // Update the middle item in place by matching ID.
        var updatedSecond = second
        updatedSecond.name = "Admin Web"
        updatedSecond.localPort = 18080
        updatedSecond.remoteHost = "app.internal"
        updatedSecond.remotePort = 8443
        updatedSecond.autoStart = true

        PortForwardStore.upsert(updatedSecond, defaults: defaults)

        let all = PortForwardStore.all(defaults: defaults)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all, [first, updatedSecond, third])

        // Verify persistence under the expected UserDefaults key.
        let storedData = try XCTUnwrap(defaults.data(forKey: PortForwardStore.storageKey))
        let decoded = try JSONDecoder().decode([SavedPortForward].self, from: storedData)
        XCTAssertEqual(decoded, [first, updatedSecond, third])
    }

    func testListHostIsolation() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostA = UUID()
        let hostB = UUID()
        let hostC = UUID()

        let a1 = SavedPortForward(hostID: hostA, name: "A1", localPort: 3001, remotePort: 3000)
        let b1 = SavedPortForward(hostID: hostB, name: "B1", localPort: 4001, remotePort: 4000)
        let a2 = SavedPortForward(hostID: hostA, name: "A2", localPort: 3002, remotePort: 3002)

        PortForwardStore.upsert(a1, defaults: defaults)
        PortForwardStore.upsert(b1, defaults: defaults)
        PortForwardStore.upsert(a2, defaults: defaults)

        XCTAssertEqual(PortForwardStore.list(for: hostA, defaults: defaults), [a1, a2])
        XCTAssertEqual(PortForwardStore.list(for: hostB, defaults: defaults), [b1])
        XCTAssertEqual(PortForwardStore.list(for: hostC, defaults: defaults), [])
    }

    func testDeleteByIDAndDeleteAllForHost() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostA = UUID()
        let hostB = UUID()

        let a1 = SavedPortForward(hostID: hostA, name: "A1", localPort: 5001, remotePort: 5000)
        let a2 = SavedPortForward(hostID: hostA, name: "A2", localPort: 5002, remotePort: 5000)
        let b1 = SavedPortForward(hostID: hostB, name: "B1", localPort: 6001, remotePort: 6000)

        PortForwardStore.upsert(a1, defaults: defaults)
        PortForwardStore.upsert(a2, defaults: defaults)
        PortForwardStore.upsert(b1, defaults: defaults)

        // Deleting an unknown ID leaves all entries untouched.
        PortForwardStore.delete(id: UUID(), defaults: defaults)
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [a1, a2, b1])

        // Deleting one rule removes only that rule.
        PortForwardStore.delete(id: a1.id, defaults: defaults)
        XCTAssertEqual(PortForwardStore.list(for: hostA, defaults: defaults), [a2])
        XCTAssertEqual(PortForwardStore.list(for: hostB, defaults: defaults), [b1])

        // Deleting all rules for hostA leaves hostB's rules intact.
        PortForwardStore.upsert(a1, defaults: defaults)
        PortForwardStore.deleteAll(for: hostA, defaults: defaults)
        XCTAssertEqual(PortForwardStore.list(for: hostA, defaults: defaults), [])
        XCTAssertEqual(PortForwardStore.list(for: hostB, defaults: defaults), [b1])
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [b1])

        // Deleting all for a host with no rules is a no-op.
        PortForwardStore.deleteAll(for: UUID(), defaults: defaults)
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [b1])

        // Deleting final rule clears the store.
        PortForwardStore.delete(id: b1.id, defaults: defaults)
        XCTAssertEqual(PortForwardStore.all(defaults: defaults), [])
    }

    func testDisplayTitleRouteDescriptionDefaultsAndHashable() {
        let hostID = UUID()

        let named = SavedPortForward(
            hostID: hostID,
            name: "Postgres",
            localPort: 5432,
            remoteHost: "127.0.0.1",
            remotePort: 5432
        )
        XCTAssertEqual(named.displayTitle, "Postgres")
        XCTAssertEqual(named.routeDescription, "localhost:5432 → 127.0.0.1:5432")
        XCTAssertFalse(named.autoStart)

        let paddedName = SavedPortForward(
            hostID: hostID,
            name: "  Redis Cache \n",
            localPort: 6379,
            remoteHost: "redis.internal",
            remotePort: 6379
        )
        XCTAssertEqual(paddedName.displayTitle, "Redis Cache")
        XCTAssertEqual(paddedName.routeDescription, "localhost:6379 → redis.internal:6379")

        let emptyName = SavedPortForward(
            hostID: hostID,
            localPort: 0,
            remotePort: 8080
        )
        XCTAssertEqual(emptyName.name, "")
        XCTAssertEqual(emptyName.remoteHost, "127.0.0.1")
        XCTAssertEqual(emptyName.displayTitle, "127.0.0.1:8080")
        XCTAssertEqual(emptyName.routeDescription, "localhost:auto → 127.0.0.1:8080")

        let whitespaceOnlyName = SavedPortForward(
            hostID: hostID,
            name: "   \t\n  ",
            localPort: 0,
            remoteHost: "db.internal",
            remotePort: 5432,
            autoStart: true
        )
        XCTAssertEqual(whitespaceOnlyName.displayTitle, "db.internal:5432")
        XCTAssertEqual(whitespaceOnlyName.routeDescription, "localhost:auto → db.internal:5432")

        let set: Set<SavedPortForward> = [named, named, emptyName]
        XCTAssertEqual(set.count, 2)
    }
}
