import Foundation
import SwiftData
import os
import Store

enum AppContainer {
    private static let log = Logger(subsystem: "com.peculiarengineer.termapp", category: "AppContainer")
    static let cloudKitContainerID = "iCloud.com.peculiarengineer.termapp"

    /// Read once per launch; Keychain callers use it so they match the container until the next launch.
    static let syncEnabledAtLaunch: Bool = UserDefaults.standard.bool(forKey: "sync.enabled")

    /// Builds the Host container. CloudKit is on only when `syncEnabledAtLaunch` is true.
    static func make() -> ModelContainer {
        let schema = Schema([Host.self])
        if syncEnabledAtLaunch {
            let synced = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainerID))
            do {
                return try ModelContainer(for: schema, configurations: [synced])
            } catch {
                // A CloudKit setup failure must not crash every launch: turn sync off and open the local store.
                log.error("CloudKit container failed, sync disabled: \(String(describing: error), privacy: .public)")
                UserDefaults.standard.set(false, forKey: "sync.enabled")
            }
        }
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Could not create local ModelContainer: \(error)")
        }
    }
}
