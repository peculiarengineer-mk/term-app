import SwiftUI
import SwiftData
import SSHKit
import Store

/// Reconnects dead sessions when the app returns to the foreground. Every reconnect runs through
/// `HostConnectionModel` (same host-key check and auth prompts as a first connect).
///
/// - Found dead by the became-active probe pass: reconnect automatically (saved credentials), with a
///   short backoff for network errors.
/// - Ended while the app is active (remote `exit`, server close): in-tab Reconnect / Close Tab overlay.
@MainActor
final class ReconnectCoordinator {
    private let manager: SessionManager
    private let monitor: AppPhaseMonitor
    private let container: ModelContainer

    @MainActor private final class Entry {
        let model: HostConnectionModel
        var started: Bool
        /// True when started by the became-active pass (not by a session ending while active).
        let auto: Bool
        var retries = 0
        var retryTask: Task<Void, Never>?
        init(model: HostConnectionModel, started: Bool, auto: Bool) {
            self.model = model; self.started = started; self.auto = auto
        }
        var isConnecting: Bool { if case .connecting = model.phase { return true } else { return false } }
        func cancel() {
            retryTask?.cancel(); retryTask = nil
            model.onConnected = nil; model.onFailed = nil
            model.teardown()
        }
    }
    private var entries: [UUID: Entry] = [:]
    /// Sessions being probed by the current became-active pass; their disconnect is the pass's business.
    private var autoPending: Set<UUID> = []
    private var probes: [UUID: Task<Void, Never>] = [:]
    /// Which bridge a session's state watcher belongs to (a replaced bridge means a new watcher).
    private var watched: [UUID: ObjectIdentifier] = [:]
    private var watchers: [UUID: Task<Void, Never>] = [:]
    /// Latest state seen by each session's watcher.
    private var latest: [UUID: SessionState] = [:]

    private static let maxRetries = 3

    init(manager: SessionManager, monitor: AppPhaseMonitor, container: ModelContainer) {
        self.manager = manager; self.monitor = monitor; self.container = container
    }

    private static var shared: ReconnectCoordinator?

    /// Starts the one app-wide coordinator; later calls (other windows appearing) do nothing.
    static func startShared(manager: SessionManager, container: ModelContainer) {
        guard shared == nil else { return }
        let c = ReconnectCoordinator(manager: manager, monitor: AppPhaseMonitor(), container: container)
        shared = c
        c.start()
    }

    func start() {
        monitor.onBecameActive = { [weak self] in self?.appBecameActive() }
        monitor.onBecameBackground = { [weak self] in self?.appBecameBackground() }
        monitor.start()
        watchSessions()
    }

    // MARK: Phase changes

    /// True from going to the background until the next became-active pass. A connection that died
    /// while suspended reports its drop during the background → inactive → active transition; that
    /// belongs to the pass (probe, then automatic reconnect), not to the "ended while in front" overlay.
    private var resuming = false

    private func appBecameActive() {
        resuming = false
        watchSessions()
        // A failed automatic reconnect starts over with the saved credentials.
        for (id, entry) in entries where entry.auto {
            if case .failed = entry.model.phase {
                dropEntry(id)
                manager.session(id: id)?.overlay = nil  // its overlay belongs to the dropped entry
            }
        }
        for live in manager.sessions where entries[live.id] == nil && probes[live.id] == nil && live.overlay == nil {
            let id = live.id, bridgeID = ObjectIdentifier(live.bridge), session = live.session
            switch latest[id] {
            case .disconnected:
                reconnect(live, auto: true)  // already dead: no probe needed
                continue
            case .connected, nil:
                break  // nil: its watcher has not seen a state yet; sessions are only handed over once connected
            default:
                continue  // connecting, authenticating or awaiting a host-key decision
            }
            autoPending.insert(id)
            probes[id] = Task { [weak self] in
                // Active liveness check: a half-open socket must not look alive for minutes.
                let alive = await session.probe(timeout: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.probes[id] = nil
                if !alive, let current = self.manager.session(id: id), ObjectIdentifier(current.bridge) == bridgeID {
                    self.reconnect(current, auto: true)
                }
                self.autoPending.remove(id)
            }
        }
    }

    private func appBecameBackground() {
        resuming = true
        for t in probes.values { t.cancel() }
        probes = [:]
        autoPending = []
        // Cancel in-flight automatic work; the next activation starts again. Entries waiting on the
        // user (host-key prompt, auth input, or a Reconnect tap) stay, so switching to a password
        // manager does not lose the prompt.
        for (id, entry) in entries where entry.auto && (entry.retryTask != nil || (entry.started && entry.isConnecting)) {
            dropEntry(id)
            manager.session(id: id)?.overlay = nil
        }
    }

    // MARK: Watching

    /// Makes sure each live session has a state watcher on its current connection.
    private func watchSessions() {
        let ids = Set(manager.sessions.map(\.id))
        for id in Array(watchers.keys) where !ids.contains(id) {
            watchers[id]?.cancel(); watchers[id] = nil; watched[id] = nil; latest[id] = nil
            probes[id]?.cancel(); probes[id] = nil; autoPending.remove(id)
        }
        for id in Array(entries.keys) where !ids.contains(id) { dropEntry(id) }
        for live in manager.sessions {
            let bridgeID = ObjectIdentifier(live.bridge)
            if watched[live.id] == bridgeID { continue }
            watchers[live.id]?.cancel()
            watched[live.id] = bridgeID
            latest[live.id] = nil
            let id = live.id, states = live.session.state
            watchers[id] = Task { [weak self] in
                var ending: SSHError?
                for await s in states {
                    if Task.isCancelled { return }
                    self?.recordState(id, bridge: bridgeID, s)
                    if case .disconnected(let e) = s { ending = e; break }
                }
                if Task.isCancelled { return }
                self?.markDead(id, bridge: bridgeID, error: ending)
            }
        }
    }

    private func recordState(_ id: UUID, bridge: ObjectIdentifier, _ state: SessionState) {
        guard watched[id] == bridge else { return }
        latest[id] = state
    }

    private func markDead(_ id: UUID, bridge: ObjectIdentifier, error: SSHError?) {
        // Relies on SessionManager.replace/close swapping or removing the session before closing the old connection.
        guard let live = manager.session(id: id), ObjectIdentifier(live.bridge) == bridge else { return }
        guard monitor.phase != .background, !resuming, entries[id] == nil, !autoPending.contains(id) else { return }
        // Ended while the app is in front: a clean end (exit, server close) asks; a transport error retries.
        reconnect(live, auto: error != nil)
    }

    // MARK: Reconnect

    private struct HostSnapshot {
        let model: HostConnectionModel
        let tmuxCommand: String?
        let needsUser: Bool
    }

    private func snapshot(_ id: UUID) -> HostSnapshot? {
        let context = container.mainContext
        var d = FetchDescriptor<Host>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let host = (try? context.fetch(d))?.first else { return nil }
        var needsUser = host.authMethod == "keyboardInteractive"
            || (host.authMethod == "password" && HostSecrets.password(for: host.id) == nil)
        if host.authMethod == "key" {
            let store = KeyStore()
            if let key = (try? store.list())?.first(where: { $0.id == host.keyID }) {
                if key.isEncrypted, ((try? store.passphrase(for: key)) ?? nil) == nil { needsUser = true }
            } else {
                needsUser = true  // key missing (nil keyID or not in the key store)
            }
        }
        return HostSnapshot(model: HostConnectionModel(host: host), tmuxCommand: host.tmuxCommand, needsUser: needsUser)
    }

    private func reconnect(_ live: LiveSession, auto: Bool) {
        let id = live.id
        if entries[id] != nil { return }  // already reconnecting or waiting on the user
        guard let snap = snapshot(live.hostID) else {
            live.overlay = AnyView(HostGoneView(onClose: { [weak self] in self?.close(id) }))
            return
        }
        let autoStart = auto && !snap.needsUser
        let entry = Entry(model: snap.model, started: autoStart, auto: auto)
        entries[id] = entry
        let tmux = snap.tmuxCommand
        snap.model.onConnected = { [weak self, weak entry] conn, bridge in
            guard let self else { Task { await conn.close() }; return }
            // The tab may have been closed (or the entry dropped) while connecting: don't leak the connection.
            guard let entry, self.entries[id] === entry, self.manager.session(id: id) != nil else {
                Task { await conn.close() }
                return
            }
            self.entries[id] = nil
            entry.cancel()
            self.manager.replace(id, session: conn, bridge: bridge)
            self.manager.session(id: id)?.overlay = nil
            TmuxAttach.send(tmux, via: bridge)
            self.watchSessions()
        }
        if auto {
            snap.model.onFailed = { [weak self, weak entry] network in
                guard let self, let entry, self.entries[id] === entry, network,
                      entry.retries < Self.maxRetries, self.monitor.phase != .background else { return }
                entry.retries += 1
                let delay = 1 << (entry.retries - 1)  // 1 s, 2 s, 4 s
                entry.retryTask = Task { [weak entry] in
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { return }
                    entry?.retryTask = nil  // fired: no longer a pending retry
                    entry?.model.retry()
                }
            }
        }
        showOverlay(live)
        if autoStart { snap.model.start() }
    }

    private func showOverlay(_ live: LiveSession) {
        let id = live.id
        guard let entry = entries[id] else { return }
        live.overlay = AnyView(ReconnectOverlay(model: entry.model, title: live.title,
                                                started: entry.started,
                                                onReconnect: { [weak self] in self?.userStarted(id) },
                                                onClose: { [weak self] in self?.close(id) }))
    }

    private func userStarted(_ id: UUID) {
        guard let entry = entries[id], let live = manager.session(id: id) else { return }
        entry.started = true
        showOverlay(live)
        entry.model.start()
    }

    private func dropEntry(_ id: UUID) {
        entries[id]?.cancel()
        entries[id] = nil
    }

    private func close(_ id: UUID) {
        dropEntry(id)
        manager.close(id)
        watchSessions()
    }
}

/// Re-renders when the model's phase changes; `started` flips through a fresh overlay value.
private struct ReconnectOverlay: View {
    let model: HostConnectionModel
    let title: String
    let started: Bool
    let onReconnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ReconnectPromptView(model: model, title: title, onClose: onClose, started: started, onReconnect: onReconnect)
    }
}
