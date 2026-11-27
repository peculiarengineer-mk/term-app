import Foundation
import Store
import SwiftData
import XCTest
@testable import TermApp

final class AppContainerTests: XCTestCase {
    private enum SampleCloudKitError: Error {
        case unavailable
    }

    private enum SampleLocalStoreError: Error {
        case corrupted
    }

    private final class PartiallyFailingFileManager: FileManager {
        let failingPath: String

        init(failingPath: String) {
            self.failingPath = failingPath
        }

        override func removeItem(at URL: URL) throws {
            if URL.path == failingPath {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: URL)
        }
    }

    private func makeIsolatedDefaults(prefix: String) throws -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "com.peculiarengineer.termapp.tests.\(prefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func resetSyncEnabledAtLaunchIfNeeded() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-reset")
        defer { cleanup() }
        _ = AppContainer.make(defaults: defaults, localContainer: makeInMemoryLocalContainer)
    }

    private func makeInMemoryLocalContainer(_ schema: Schema) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    func testMakeFallsBackToLocalWhenCloudKitThrowsObjCException() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-objc")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(true, forKey: "sync.enabled")
        defaults.set(true, forKey: SyncCoordinator.resaveKey)

        var localCalled = false
        let container = AppContainer.make(
            defaults: defaults,
            syncedContainer: { _ in
                NSException(
                    name: .internalInconsistencyException,
                    reason: "Application is missing entitlement iCloud.com.peculiarengineer.termapp",
                    userInfo: nil
                ).raise()
                return try self.makeInMemoryLocalContainer(Schema([Host.self]))
            },
            localContainer: { schema in
                localCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertTrue(localCalled)
        XCTAssertFalse(AppContainer.syncEnabledAtLaunch)
        XCTAssertFalse(defaults.bool(forKey: "sync.enabled"))
        XCTAssertFalse(defaults.bool(forKey: SyncCoordinator.resaveKey))
        XCTAssertNotNil(defaults.object(forKey: SyncCoordinator.disabledAtKey) as? Date)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testMakeFallsBackToLocalWhenCloudKitThrowsSwiftError() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-swift")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(true, forKey: "sync.enabled")
        defaults.set(true, forKey: SyncCoordinator.resaveKey)

        var localCalled = false
        let container = AppContainer.make(
            defaults: defaults,
            syncedContainer: { _ in
                throw SampleCloudKitError.unavailable
            },
            localContainer: { schema in
                localCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertTrue(localCalled)
        XCTAssertFalse(AppContainer.syncEnabledAtLaunch)
        XCTAssertFalse(defaults.bool(forKey: "sync.enabled"))
        XCTAssertFalse(defaults.bool(forKey: SyncCoordinator.resaveKey))
        XCTAssertNotNil(defaults.object(forKey: SyncCoordinator.disabledAtKey) as? Date)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testMakeSkipsCloudKitWhenSyncDisabled() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-disabled")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(false, forKey: "sync.enabled")

        var syncedCalled = false
        var localCalled = false
        let container = AppContainer.make(
            defaults: defaults,
            syncedContainer: { schema in
                syncedCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            },
            localContainer: { schema in
                localCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertFalse(syncedCalled)
        XCTAssertTrue(localCalled)
        XCTAssertFalse(AppContainer.syncEnabledAtLaunch)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    @MainActor
    func testWidgetSyncAgentsToleratesDuplicateStoredSnapshots() throws {
        let (cacheDefaults, cleanupCache) = try makeIsolatedDefaults(prefix: "widget-dup-cache")
        let (widgetDefaults, cleanupWidget) = try makeIsolatedDefaults(prefix: "widget-dup-store")
        defer {
            cleanupCache()
            cleanupWidget()
        }

        let hostID = UUID()
        let duplicateA = WidgetAgentSnapshot(
            hostID: hostID,
            hostLabel: "Box",
            sessionName: "termapp-ai-claude-app",
            agentSlug: "claude",
            agentName: "Claude Code",
            projectSlug: "app",
            status: .idle
        )
        let duplicateB = WidgetAgentSnapshot(
            hostID: hostID,
            hostLabel: "Box",
            sessionName: "termapp-ai-claude-app",
            agentSlug: "claude",
            agentName: "Claude Code",
            projectSlug: "app",
            status: .running
        )
        WidgetSnapshotStore.saveAgents([duplicateA, duplicateB], defaults: widgetDefaults)

        WidgetSyncCoordinator.syncAgents(
            liveSessions: [],
            cacheDefaults: cacheDefaults,
            widgetDefaults: widgetDefaults,
            reloadTimelines: false
        )

        let stored = WidgetSnapshotStore.loadAgents(defaults: widgetDefaults)
        XCTAssertTrue(stored.isEmpty)
    }

    func testMakeResetsStoreAndRetriesWhenFirstLocalContainerFails() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-local-retry")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(false, forKey: "sync.enabled")

        var localAttempts = 0
        var resetCount = 0
        var inMemoryCalled = false

        let container = AppContainer.make(
            defaults: defaults,
            localContainer: { schema in
                localAttempts += 1
                if localAttempts == 1 {
                    throw SampleLocalStoreError.corrupted
                }
                return try self.makeInMemoryLocalContainer(schema)
            },
            resetStore: {
                XCTAssertEqual(localAttempts, 1)
                resetCount += 1
            },
            inMemoryContainer: { schema in
                inMemoryCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertEqual(localAttempts, 2)
        XCTAssertEqual(resetCount, 1)
        XCTAssertFalse(inMemoryCalled)
        XCTAssertFalse(AppContainer.syncEnabledAtLaunch)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testMakeResetsStoreAndRetriesWhenFirstLocalContainerThrowsObjCException() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-local-objc")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(false, forKey: "sync.enabled")

        var localAttempts = 0
        var resetCount = 0
        var inMemoryCalled = false

        let container = AppContainer.make(
            defaults: defaults,
            localContainer: { schema in
                localAttempts += 1
                if localAttempts == 1 {
                    NSException(
                        name: .internalInconsistencyException,
                        reason: "Simulated CoreData/SQLite Obj-C exception",
                        userInfo: nil
                    ).raise()
                }
                return try self.makeInMemoryLocalContainer(schema)
            },
            resetStore: {
                XCTAssertEqual(localAttempts, 1)
                resetCount += 1
            },
            inMemoryContainer: { schema in
                inMemoryCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertEqual(localAttempts, 2)
        XCTAssertEqual(resetCount, 1)
        XCTAssertFalse(inMemoryCalled)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testMakeFallsBackToInMemoryContainerWhenLocalContainerFailsAfterReset() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-local-inmemory")
        defer {
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        defaults.set(false, forKey: "sync.enabled")

        var localAttempts = 0
        var resetCount = 0
        var inMemoryAttempts = 0

        let container = AppContainer.make(
            defaults: defaults,
            localContainer: { _ in
                localAttempts += 1
                throw SampleLocalStoreError.corrupted
            },
            resetStore: {
                resetCount += 1
            },
            inMemoryContainer: { schema in
                inMemoryAttempts += 1
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertEqual(localAttempts, 2)
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(inMemoryAttempts, 1)
        XCTAssertFalse(AppContainer.syncEnabledAtLaunch)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testMakeRecoversFromCorruptSQLiteStoreOnDisk() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults(prefix: "appcontainer-corrupt-sqlite")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcontainer-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            cleanup()
            try? resetSyncEnabledAtLaunchIfNeeded()
        }

        let storeURL = tempDir.appendingPathComponent("default.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("corrupt-sqlite-header".utf8).write(to: storeURL)
        try Data("corrupt-wal".utf8).write(to: walURL)
        try Data("corrupt-shm".utf8).write(to: shmURL)

        defaults.set(false, forKey: "sync.enabled")

        var localAttempts = 0
        var inMemoryCalled = false
        let container = AppContainer.make(
            defaults: defaults,
            localContainer: { schema in
                localAttempts += 1
                let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: [config])
            },
            resetStore: {
                AppContainer.removeStoreFiles(at: storeURL)
            },
            inMemoryContainer: { schema in
                inMemoryCalled = true
                return try self.makeInMemoryLocalContainer(schema)
            }
        )

        XCTAssertEqual(localAttempts, 2)
        XCTAssertFalse(inMemoryCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Host>()).count, 0)
    }

    func testRemoveStoreFilesRemovesStoreAndSidecarsInTempDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcontainer-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("default.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        let unrelatedURL = tempDir.appendingPathComponent("keep.txt")

        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)
        try Data("keep".utf8).write(to: unrelatedURL)

        AppContainer.removeStoreFiles(at: storeURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testRemoveStoreFilesSucceedsWhenSidecarsOrFilesAreAbsent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcontainer-remove-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("default.store")
        try Data("store-only".utf8).write(to: storeURL)

        AppContainer.removeStoreFiles(at: storeURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        // Repeating when all files are already absent must also complete cleanly.
        AppContainer.removeStoreFiles(at: storeURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testRemoveStoreFilesLogsAndContinuesOnRemovalError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcontainer-remove-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("default.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let failingFM = PartiallyFailingFileManager(failingPath: storeURL.path)
        AppContainer.removeStoreFiles(at: storeURL, fileManager: failingFM)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
    }
}
