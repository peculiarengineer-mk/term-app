import SwiftUI
import SSHKit
import TermUI

/// One live SSH session: the connection, its terminal bridge and the host it belongs to.
@MainActor @Observable
final class LiveSession: Identifiable {
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
    /// Drawn over the terminal by whichever tab shows this session (T9 uses it for the Reconnect prompt).
    var overlay: AnyView?

    init(id: UUID = UUID(), hostID: UUID, title: String, session: any Session, bridge: SessionBridge) {
        self.id = id; self.hostID = hostID; self.title = title
        self.session = session; self.bridge = bridge
        let c = TerminalController()
        controller = c
        bar = ExtraKeysBar(controller: c)
    }

    fileprivate func replace(session: any Session, bridge: SessionBridge) {
        self.session = session; self.bridge = bridge
    }
}

/// Owns every live session across all windows, so one object can drive reconnects everywhere.
@MainActor @Observable
final class SessionManager {
    private(set) var sessions: [LiveSession] = []

    func session(id: UUID) -> LiveSession? { sessions.first { $0.id == id } }

    @discardableResult
    func open(hostID: UUID, title: String, session: any Session, bridge: SessionBridge) -> LiveSession {
        let live = LiveSession(hostID: hostID, title: title, session: session, bridge: bridge)
        sessions.append(live)
        return live
    }

    /// Shows the session in `window`, taking it away from any other window.
    func show(_ id: UUID, in window: UUID) { session(id: id)?.windowID = window }

    /// Detaches the session from its window (it is about to be shown elsewhere).
    func detach(_ id: UUID) { session(id: id)?.windowID = nil }

    /// Swaps the connection and bridge in place (same id); views keyed by the bridge follow.
    /// The previous connection is closed.
    func replace(_ id: UUID, session: any Session, bridge: SessionBridge) {
        guard let live = self.session(id: id) else { return }
        let old = live.session
        live.replace(session: session, bridge: bridge)
        Task { await old.close() }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let live = sessions.remove(at: i)
        let session = live.session
        Task { await session.close() }
    }
}

private struct OpenTabKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Set by `SessionTabsView`: shows a just-opened session as a tab in this window.
    var openSessionTab: @MainActor (UUID) -> Void {
        get { self[OpenTabKey.self] }
        set { self[OpenTabKey.self] = newValue }
    }
}
