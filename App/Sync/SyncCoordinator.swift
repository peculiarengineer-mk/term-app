import Foundation
import SwiftData
import CoreData
import Store
import os

/// With iCloud sync on at launch: re-saves hosts once, dedupes hosts, promotes saved host passwords
/// and trusted host keys to synchronizable Keychain items, then dedupes again after remote changes.
/// Does nothing when sync is off. Works in its own `ModelContext`.
@ModelActor
actor SyncCoordinator {
    static let resaveKey = "sync.initialResaveDone"
    /// Set by `syncTurnedOff()`; hosts edited after it are re-saved on the next sync launch.
    static let disabledAtKey = "sync.disabledAt"
    private static let maxDedupeRetries = 3

    // @unchecked Sendable: guarded by NSLock; observer/task are updated by the actor and cleared in deinit.
    private final class LifecycleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observer: NSObjectProtocol?
        private var pending: Task<Void, Never>?

        var hasObserver: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observer != nil
        }

        func setObserver(_ token: NSObjectProtocol) {
            lock.lock()
            let old = observer
            observer = token
            lock.unlock()
            if let old {
                NotificationCenter.default.removeObserver(old)
            }
        }

        func replacePending(_ task: Task<Void, Never>) {
            lock.lock()
            let old = pending
            pending = task
            lock.unlock()
            old?.cancel()
        }

        func invalidate() {
            lock.lock()
            let currentObserver = observer
            let currentPending = pending
            observer = nil
            pending = nil
            lock.unlock()
            currentPending?.cancel()
            if let currentObserver {
                NotificationCenter.default.removeObserver(currentObserver)
            }
        }
    }

    private let lifecycle = LifecycleBox()
    private var started = false
    private var dedupeRetryCount = 0
    private let logger = Logger(subsystem: "com.peculiarengineer.termapp", category: "sync")

    deinit {
        lifecycle.invalidate()
    }

    func start() async {
        // `sync.enabled` is re-checked because AppContainer.make() turns it off (for the next launch)
        // when the CloudKit container fails and it falls back to the local store.
        guard AppContainer.syncEnabledAtLaunch else { return }
        guard UserDefaults.standard.bool(forKey: "sync.enabled") else {
            Self.syncTurnedOff()  // the CloudKit fallback turned sync off without going through Settings
            return
        }
        guard !started, !lifecycle.hasObserver else { return }
        started = true
        resaveOnce()
        dedupe()
        await Self.promoteKeychainItems(logger: logger)
        guard !lifecycle.hasObserver else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.scheduleDedupe() }
        }
        lifecycle.setObserver(token)
    }

    /// Called whenever sync goes from on to off (Settings, or the CloudKit fallback at launch): the
    /// next sync-on launch re-saves hosts edited from now on. `disabledAt` is recorded only after a
    /// completed re-save; otherwise older hosts may never have been exported and all are re-saved.
    static func syncTurnedOff() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: resaveKey) {
            defaults.set(Date(), forKey: disabledAtKey)
        }
        defaults.set(false, forKey: resaveKey)
    }

    /// Once per sync-on period: touch hosts in place so hosts created or edited while sync was off
    /// get exported. After an earlier sync period only hosts edited since sync was turned off are
    /// touched, so stale copies never get a fresh `updatedAt` that would beat newer remote edits.
    /// The flag is set only after a successful save; `syncTurnedOff()` clears it.
    private func resaveOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.resaveKey) else { return }
        let disabledAt = defaults.object(forKey: Self.disabledAtKey) as? Date
        do {
            let hosts = try modelContext.fetch(FetchDescriptor<Host>())
            for host in hosts where disabledAt.map({ host.updatedAt >= $0 }) ?? true { host.touch() }
            try modelContext.save()
            UserDefaults.standard.set(true, forKey: Self.resaveKey)
        } catch {
            modelContext.rollback()
            logger.error("Initial host re-save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restarts the 1 s wait on every notification, so a burst yields one pass after it ends.
    private func scheduleDedupe() {
        dedupeRetryCount = 0
        scheduleDedupeTask(delay: .seconds(1))
    }

    private func scheduleDedupeTask(delay: Duration) {
        let task = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.dedupe()
        }
        lifecycle.replacePending(task)
    }

    private func dedupe() {
        do {
            try HostDeduper.dedupe(in: modelContext)
            dedupeRetryCount = 0
        } catch {
            modelContext.rollback()
            logger.error("Host dedupe failed: \(error.localizedDescription, privacy: .public)")
            if dedupeRetryCount < Self.maxDedupeRetries {
                dedupeRetryCount += 1
                let backoffSeconds = 1 << dedupeRetryCount
                scheduleDedupeTask(delay: .seconds(backoffSeconds))
            }
        }
    }

    /// Makes local host passwords and known-host entries synchronizable on `@MainActor` so Keychain
    /// promotions serialize cleanly with UI-driven Keychain writes. Never the reverse; key and
    /// passphrase services are not touched.
    @MainActor
    private static func promoteKeychainItems(logger: Logger) {
        let store = KeychainStore()
        for service in [KeychainService.knownHosts, KeychainService.hostPassword] {
            let items: [(account: String, data: Data, synchronizable: Bool)]
            do {
                items = try store.readAll(service: service)
            } catch {
                logger.error("Keychain read failed for \(service, privacy: .public): status \((error as? KeychainError)?.status ?? 0)")
                continue
            }
            for item in items where !item.synchronizable {
                do {
                    try store.setSynchronizable(true, service: service, account: item.account)
                } catch {
                    logger.error("Keychain promotion failed in \(service, privacy: .public): status \((error as? KeychainError)?.status ?? 0)")
                }
            }
        }
    }
}
