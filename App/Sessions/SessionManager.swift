import SwiftUI
import SwiftData
import SSHKit
import Store
import TermUI

/// One live SSH session: the connection, its terminal bridge and the host it belongs to.
@MainActor @Observable
final class LiveSession: Identifiable {
    enum ConnectionStatus: Equatable, Sendable {
        case connected, reconnecting, disconnected
    }

    let id: UUID
    let hostID: UUID
    let title: String
    private(set) var session: any Session
    private(set) var bridge: SessionBridge
    /// The window currently showing this session (nil while it is being moved). Exactly one at a time.
    fileprivate(set) var windowID: UUID?
    /// One controller and extra-keys bar per session, so font size etc. survive tab switches.
    /// (The bar holds its controller weakly; this object keeps both alive.)
    let controller: TerminalController
    let bar: ExtraKeysBar
    /// Live connection status driven by `ReconnectCoordinator` (single consumer of `session.state`).
    var connectionStatus: ConnectionStatus = .connected
    /// Drawn over the terminal by whichever tab shows this session (T9 uses it for the Reconnect prompt).
    var overlay: AnyView?
    /// What the last handshake negotiated; nil when unknown.
    var algorithms: NegotiatedAlgorithms?
    /// The user dismissed the quantum-safety banner for this session.
    var quantumNoticeDismissed = false
    /// Preserves whether the terminal should auto-focus on tab switch (cleared when user dismisses keyboard).
    var shouldAutoFocus = true
    /// Unsaved SwiftData `Host` when launched via Quick Connect; cleared once saved.
    var ephemeralHost: Host?

    init(id: UUID = UUID(), hostID: UUID, title: String, session: any Session, bridge: SessionBridge,
         algorithms: NegotiatedAlgorithms? = nil, ephemeralHost: Host? = nil) {
        self.algorithms = algorithms
        self.ephemeralHost = ephemeralHost
        self.id = id; self.hostID = hostID; self.title = title
        self.session = session; self.bridge = bridge
        let c = TerminalController(
            fontSize: AppearanceSettings.currentFontSize(),
            fontFamily: AppearanceSettings.currentFontFamily()
        )
        controller = c
        let bar = ExtraKeysBar(controller: c, theme: AppearanceSettings.currentTheme())
        bar.hapticsEnabled = AppearanceSettings.hapticsEnabled()
        bar.onDismissKeyboard = { [weak c] in c?.dismissKeyboard() }
        self.bar = bar
    }

    fileprivate func replace(session: any Session, bridge: SessionBridge, algorithms: NegotiatedAlgorithms?) {
        self.session = session; self.bridge = bridge
        self.algorithms = algorithms
        connectionStatus = .connected
        quantumNoticeDismissed = false
    }
}

/// Owns every live session across all windows, so one object can drive reconnects everywhere.
@MainActor @Observable
final class SessionManager {
    private(set) var sessions: [LiveSession] = []
    var onSessionsChanged: (() -> Void)?

    func session(id: UUID) -> LiveSession? { sessions.first { $0.id == id } }

    @discardableResult
    func open(hostID: UUID, title: String, session: any Session, bridge: SessionBridge,
              algorithms: NegotiatedAlgorithms? = nil, ephemeralHost: Host? = nil) -> LiveSession {
        let live = LiveSession(
            hostID: hostID,
            title: title,
            session: session,
            bridge: bridge,
            algorithms: algorithms,
            ephemeralHost: ephemeralHost
        )
        sessions.append(live)
        if algorithms == nil { loadAlgorithms(for: live, from: session) }
        onSessionsChanged?()
        return live
    }

    /// Inserts an ephemeral Quick-Connect host into SwiftData and marks the session saved.
    @discardableResult
    func saveEphemeralHost(for liveID: UUID, in modelContext: ModelContext) -> Bool {
        guard let live = session(id: liveID), let host = live.ephemeralHost else { return false }
        if host.modelContext == nil {
            modelContext.insert(host)
        }
        try? modelContext.save()
        live.ephemeralHost = nil
        AppHaptics.notify(.success)
        return true
    }

    /// Callers that do not pass the algorithms (host connect, reconnect) get them read from the connection.
    private func loadAlgorithms(for live: LiveSession, from session: any Session) {
        guard let conn = session as? SSHConnection else { return }
        Task { @MainActor [weak live] in
            let a = await conn.negotiatedAlgorithms()
            guard let live, live.session as AnyObject === conn else { return }
            live.algorithms = a
        }
    }

    /// Shows the session in `window`, taking it away from any other window.
    func show(_ id: UUID, in window: UUID) { session(id: id)?.windowID = window }

    /// Detaches the session from its window (it is about to be shown elsewhere).
    func detach(_ id: UUID) { session(id: id)?.windowID = nil }

    /// Swaps the connection and bridge in place (same id); views keyed by the bridge follow.
    /// The previous connection is closed.
    func replace(_ id: UUID, session: any Session, bridge: SessionBridge,
                 algorithms: NegotiatedAlgorithms? = nil) {
        guard let live = self.session(id: id) else { return }
        let old = live.session
        live.replace(session: session, bridge: bridge, algorithms: algorithms)
        if algorithms == nil { loadAlgorithms(for: live, from: session) }
        onSessionsChanged?()
        Task { await old.close() }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let live = sessions.remove(at: i)
        onSessionsChanged?()
        let session = live.session
        Task { await session.close() }
    }
}

private struct OpenTabKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID) -> Void = { _ in }
}

private struct ConnectHostKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Host) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by `SessionTabsView`: shows a just-opened session as a tab in this window.
    var openSessionTab: @MainActor (UUID) -> Void {
        get { self[OpenTabKey.self] }
        set { self[OpenTabKey.self] = newValue }
    }

    /// Set by `SessionTabsView`: starts an inline connecting tab for `Host` in this window.
    var connectHost: (@MainActor (Host) -> Void)? {
        get { self[ConnectHostKey.self] }
        set { self[ConnectHostKey.self] = newValue }
    }
}
