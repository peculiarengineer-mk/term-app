import Foundation
import SwiftData
import os
import Store

enum AppContainer {
    private static let log = Logger(subsystem: "com.peculiarengineer.termapp", category: "AppContainer")
    static let cloudKitContainerID = "iCloud.com.peculiarengineer.termapp"
    private static let syncState = OSAllocatedUnfairLock(initialState: false)

    /// Read once per launch; Keychain callers use it so they match the container until the next launch.
    private(set) static var syncEnabledAtLaunch: Bool {
        get { syncState.withLock { $0 } }
        set { syncState.withLock { $0 = newValue } }
    }

    /// Removes a SQLite-backed SwiftData store and its `-wal`/`-shm` sidecars, ignoring missing files.
    static func removeStoreFiles(at storeURL: URL, fileManager: FileManager = .default) {
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch let error as POSIXError where error.code == .ENOENT {
                continue
            } catch {
                log.error(
                    "Failed to remove SwiftData store file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Builds the Host container. CloudKit is on only when `syncEnabledAtLaunch` is true.
    static func make() -> ModelContainer {
        make(defaults: .standard)
    }

    static func make(
        defaults: UserDefaults,
        syncedContainer: (Schema) throws -> ModelContainer = { schema in
            let synced = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainerID))
            return try ModelContainer(for: schema, configurations: [synced])
        },
        localContainer: (Schema) throws -> ModelContainer = { schema in
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [local])
        },
        resetStore: () -> Void = {
            let local = ModelConfiguration(schema: Schema([Host.self]), cloudKitDatabase: .none)
            removeStoreFiles(at: local.url)
        },
        inMemoryContainer: (Schema) throws -> ModelContainer = { schema in
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [inMemory])
        }
    ) -> ModelContainer {
        let schema = Schema([Host.self])
        let requested = defaults.bool(forKey: "sync.enabled")
        syncEnabledAtLaunch = requested
        if requested {
            do {
                return try catchingObjCException {
                    try syncedContainer(schema)
                }
            } catch {
                // A CloudKit setup failure (including Obj-C NSException from CKContainer) must not crash every launch:
                // turn sync off and open the local store.
                log.error("CloudKit container failed, sync disabled: \(String(describing: error), privacy: .public)")
                syncEnabledAtLaunch = false
                defaults.set(false, forKey: "sync.enabled")
                SyncCoordinator.syncTurnedOff(defaults: defaults)
            }
        }

        do {
            return try catchingObjCException {
                try localContainer(schema)
            }
        } catch {
            // Recover from a corrupt local store or failed migration by resetting the store files and retrying once.
            log.error("Local ModelContainer failed, resetting store and retrying: \(String(describing: error), privacy: .public)")
            resetStore()
        }

        do {
            return try catchingObjCException {
                try localContainer(schema)
            }
        } catch {
            log.error("Local ModelContainer retry failed, falling back to in-memory store: \(String(describing: error), privacy: .public)")
        }

        do {
            return try catchingObjCException {
                try inMemoryContainer(schema)
            }
        } catch {
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }
}
