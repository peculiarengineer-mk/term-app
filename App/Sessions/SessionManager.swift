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
    var connectionStatus: ConnectionStatus = .connected {
        didSet {
            if connectionStatus != .connected {
                completionDebounceTask?.cancel()
                completionDebounceTask = nil
                if case .running = agentActivityState {
                    agentActivityState = .idle
                }
            }
        }
    }
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
    /// Optional AI agent launch/attach metadata when this session runs a managed AI coding agent.
    var aiAgentContext: AIAgentLaunchContext?
    /// Whether this AI agent session runs inside `tmux` (`false` when launched while `tmux` is missing).
    var isTmuxBacked: Bool
    /// The user dismissed the missing-`tmux` persistence notice for this session.
    var tmuxNoticeDismissed = false
    /// One-shot launch/attach command sent once the session is connected, then cleared.
    var pendingLaunchCommand: String?
    /// Controls visibility of the docked mobile AI Quick-Action Bar & Prompt Composer.
    var showAIAgentControls: Bool {
        didSet {
            if showAIAgentControls {
                AgentNotificationManager.shared.requestAuthorizationIfNeeded()
            } else if !isAgentActivityTracked {
                outputTailData.removeAll(keepingCapacity: false)
                agentActivityState = .idle
            }
        }
    }
    /// Preserves in-progress multi-line prompt text across tab switches.
    var aiPromptDraft: String = ""
    /// Live AI agent execution state inferred from terminal output and user input.
    var agentActivityState: AgentActivityState = .idle {
        didSet {
            if case .running = agentActivityState { return }
            completionDebounceTask?.cancel()
            completionDebounceTask = nil
        }
    }

    @ObservationIgnored private var outputTailData = Data()
    @ObservationIgnored nonisolated(unsafe) private var completionDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var visibleTerminalCount = 0
    @ObservationIgnored private var suppressedDirectInputCount = 0

    /// True while a modal tool sheet, switcher, or security sheet covers this session's terminal.
    var hasModalSheetPresented = false
    /// True while an inline popover/fallback sheet inside `TerminalPane` or `AITerminalControlsOverlay` is presented.
    var hasInlineModalPresented = false
    /// Incremented whenever direct keyboard/bar input (not quick actions) is sent on `bridge`.
    private(set) var directInputSequence: UInt64 = 0
    /// Incremented when the user taps or refocuses the terminal viewport.
    private(set) var terminalFocusSequence: UInt64 = 0

    private static let maxOutputTailBytes = 2048
    private static let completionDebounceDuration: Duration = .seconds(4)

    var isAgentActivityTracked: Bool {
        aiAgentContext != nil || showAIAgentControls
    }

    var isTerminalVisible: Bool {
        visibleTerminalCount > 0 && !hasModalSheetPresented && !hasInlineModalPresented
    }

    private var activityAgentName: String {
        aiAgentContext?.agent.name ?? title
    }

    init(
        id: UUID = UUID(),
        hostID: UUID,
        title: String,
        session: any Session,
        bridge: SessionBridge,
        algorithms: NegotiatedAlgorithms? = nil,
        ephemeralHost: Host? = nil,
        aiAgentContext: AIAgentLaunchContext? = nil,
        pendingLaunchCommand: String? = nil,
        isTmuxBacked: Bool? = nil
    ) {
        self.algorithms = algorithms
        self.ephemeralHost = ephemeralHost
        self.aiAgentContext = aiAgentContext
        self.isTmuxBacked = isTmuxBacked ?? aiAgentContext?.isTmuxBacked ?? true
        self.pendingLaunchCommand = pendingLaunchCommand
        self.showAIAgentControls = aiAgentContext != nil
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
        attachActivityObservers(to: bridge)
    }

    func terminalAppeared() {
        visibleTerminalCount += 1
    }

    func terminalDisappeared() {
        visibleTerminalCount = max(0, visibleTerminalCount - 1)
    }

    /// Signals that the user interacted with or refocused the terminal viewport.
    func recordTerminalFocusInteraction() {
        terminalFocusSequence &+= 1
    }

    /// Sends quick-action deck bytes without treating them as direct terminal keyboard typing.
    func sendQuickAction(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if bridge.onUserInput != nil {
            suppressedDirectInputCount += 1
        }
        bridge.send(bytes)
    }

    func cleanupActivityTracking() {
        completionDebounceTask?.cancel()
        completionDebounceTask = nil
        suppressedDirectInputCount = 0
        outputTailData.removeAll(keepingCapacity: false)
        bridge.onOutputChunk = nil
        bridge.onUserInput = nil
    }

    /// Dispatches `pendingLaunchCommand` once after the shell connects and clears it so reconnects never re-send.
    func dispatchPendingLaunchCommandIfReady() {
        guard connectionStatus == .connected,
              let rawCommand = pendingLaunchCommand else {
            return
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLaunchCommand = nil
        guard !command.isEmpty else { return }

        let targetBridge = bridge
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.connectionStatus == .connected,
                  self.bridge === targetBridge else {
                return
            }
            if targetBridge.onUserInput != nil {
                self.suppressedDirectInputCount += 1
            }
            targetBridge.send(Array((command + "\r").utf8))
        }
    }

    fileprivate func replace(session: any Session, bridge: SessionBridge, algorithms: NegotiatedAlgorithms?) {
        cleanupActivityTracking()
        self.session = session; self.bridge = bridge
        self.algorithms = algorithms
        connectionStatus = .connected
        quantumNoticeDismissed = false
        hasModalSheetPresented = false
        hasInlineModalPresented = false
        agentActivityState = .idle
        attachActivityObservers(to: bridge)
    }

    private func attachActivityObservers(to targetBridge: SessionBridge) {
        targetBridge.onOutputChunk = { [weak self, weak targetBridge] chunk in
            Task { @MainActor [weak self] in
                guard let self, let targetBridge, self.bridge === targetBridge else { return }
                self.handleOutputChunk(chunk)
            }
        }
        targetBridge.onUserInput = { [weak self, weak targetBridge] bytes in
            Task { @MainActor [weak self] in
                guard let self, let targetBridge, self.bridge === targetBridge else { return }
                self.handleUserInput(bytes)
            }
        }
    }

    private func handleOutputChunk(_ chunk: [UInt8]) {
        guard isAgentActivityTracked, !chunk.isEmpty else { return }

        outputTailData.append(contentsOf: chunk)
        if outputTailData.count > Self.maxOutputTailBytes {
            var trimmed = outputTailData.suffix(Self.maxOutputTailBytes)
            while let first = trimmed.first, (first & 0xC0) == 0x80 {
                trimmed = trimmed.dropFirst()
            }
            outputTailData = Data(trimmed)
        }

        let tailText = String(decoding: outputTailData, as: UTF8.self)
        if let approvalPrompt = AgentActivityDetector.detectApprovalPrompt(in: tailText) {
            completionDebounceTask?.cancel()
            completionDebounceTask = nil
            let nextState = AgentActivityState.waitingForApproval(prompt: approvalPrompt)
            if agentActivityState != nextState {
                agentActivityState = nextState
                AgentNotificationManager.shared.notifyIfNeeded(
                    sessionTitle: title,
                    agentName: activityAgentName,
                    state: nextState,
                    isActiveVisibleTab: isTerminalVisible,
                    sessionID: id
                )
            }
            return
        }

        let chunkText = String(decoding: chunk, as: UTF8.self)
        guard AgentActivityDetector.isMeaningfulOutput(chunkText) else { return }

        if agentActivityState != .running {
            agentActivityState = .running
        }
        scheduleCompletionDebounce()
    }

    private func handleUserInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !Self.isTerminalQueryResponse(bytes) else { return }

        if suppressedDirectInputCount > 0 {
            suppressedDirectInputCount -= 1
        } else {
            directInputSequence &+= 1
        }

        outputTailData.removeAll(keepingCapacity: true)
        completionDebounceTask?.cancel()
        completionDebounceTask = nil

        let resetState: AgentActivityState = isAgentActivityTracked ? .running : .idle
        if agentActivityState != resetState {
            agentActivityState = resetState
        }
    }

    private func scheduleCompletionDebounce() {
        completionDebounceTask?.cancel()
        completionDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.completionDebounceDuration)
            guard !Task.isCancelled,
                  let self,
                  self.isAgentActivityTracked,
                  self.connectionStatus == .connected,
                  case .running = self.agentActivityState else {
                return
            }
            self.agentActivityState = .completed
            AgentNotificationManager.shared.notifyIfNeeded(
                sessionTitle: self.title,
                agentName: self.activityAgentName,
                state: .completed,
                isActiveVisibleTab: self.isTerminalVisible,
                sessionID: self.id
            )
        }
    }

    private static func isTerminalQueryResponse(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0x1B else { return false }
        if bytes[1] == 0x5D {
            // OSC responses (e.g. color queries ESC ] 10 ; rgb:...)
            return true
        }
        guard bytes[1] == 0x5B, let last = bytes.last else { return false }
        if last == 0x52 { // DSR cursor report: ESC [ <digits/;> R
            return bytes.dropFirst(2).dropLast().allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3B || $0 == 0x3F
            }
        }
        if last == 0x63 { // DA response: ESC [ ? <digits/;> c
            return bytes.dropFirst(2).dropLast().allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3B || $0 == 0x3F || $0 == 0x3E
            }
        }
        return false
    }
}

/// Owns every live session across all windows, so one object can drive reconnects everywhere.
@MainActor @Observable
final class SessionManager {
    private(set) var sessions: [LiveSession] = []
    private(set) var pendingMergeBackSessionID: UUID?
    private(set) var pendingNewTabRequestID: UUID?
    var onSessionsChanged: (() -> Void)?

    func session(id: UUID) -> LiveSession? { sessions.first { $0.id == id } }

    func connectedSession(for hostID: UUID) -> LiveSession? {
        sessions.first { $0.hostID == hostID && $0.connectionStatus == .connected }
    }

    @discardableResult
    func open(
        hostID: UUID,
        title: String,
        session: any Session,
        bridge: SessionBridge,
        algorithms: NegotiatedAlgorithms? = nil,
        ephemeralHost: Host? = nil,
        aiAgentContext: AIAgentLaunchContext? = nil,
        pendingLaunchCommand: String? = nil,
        isTmuxBacked: Bool? = nil
    ) -> LiveSession {
        let live = LiveSession(
            hostID: hostID,
            title: title,
            session: session,
            bridge: bridge,
            algorithms: algorithms,
            ephemeralHost: ephemeralHost,
            aiAgentContext: aiAgentContext,
            pendingLaunchCommand: pendingLaunchCommand,
            isTmuxBacked: isTmuxBacked
        )
        sessions.append(live)
        if aiAgentContext != nil {
            AgentNotificationManager.shared.requestAuthorizationIfNeeded()
        }
        if algorithms == nil { loadAlgorithms(for: live, from: session) }
        startAutoPortForwards(for: hostID, on: session)
        onSessionsChanged?()
        return live
    }

    private func startAutoPortForwards(for hostID: UUID, on session: any Session) {
        guard let conn = session as? SSHConnection else { return }
        let rules = PortForwardStore.list(for: hostID).filter(\.autoStart)
        guard !rules.isEmpty else { return }
        Task.detached {
            for rule in rules {
                _ = try? await conn.startLocalForward(
                    PortForwardRule(
                        id: rule.id,
                        name: rule.name,
                        localPort: rule.localPort,
                        remoteHost: rule.remoteHost,
                        remotePort: rule.remotePort
                    )
                )
            }
        }
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

    /// Detaches `id` from a secondary window and queues it to reopen in the main window's tab bar.
    func requestMergeBack(_ id: UUID) {
        guard session(id: id) != nil else { return }
        detach(id)
        pendingMergeBackSessionID = id
    }

    /// Returns and clears any pending merge-back session ID for the main window.
    func consumePendingMergeBackSessionID() -> UUID? {
        defer { pendingMergeBackSessionID = nil }
        return pendingMergeBackSessionID
    }

    /// Requests that the main window switch to the Hosts tab for a new connection (e.g. Cmd+T from a secondary window).
    func requestNewTabInMainWindow() {
        pendingNewTabRequestID = UUID()
    }

    /// Returns and clears any pending new-tab navigation request for the main window.
    func consumePendingNewTabRequestID() -> UUID? {
        defer { pendingNewTabRequestID = nil }
        return pendingNewTabRequestID
    }

    /// Swaps the connection and bridge in place (same id); views keyed by the bridge follow.
    /// The previous connection is closed.
    func replace(_ id: UUID, session: any Session, bridge: SessionBridge,
                 algorithms: NegotiatedAlgorithms? = nil) {
        guard let live = self.session(id: id) else { return }
        let old = live.session
        live.replace(session: session, bridge: bridge, algorithms: algorithms)
        if algorithms == nil { loadAlgorithms(for: live, from: session) }
        startAutoPortForwards(for: live.hostID, on: session)
        onSessionsChanged?()
        Task { await old.close() }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let live = sessions.remove(at: i)
        live.cleanupActivityTracking()
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

private struct LaunchAIAgentKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Host, AIAgentLaunchContext, String) -> Void)? = nil
}

private struct RunTerminalCommandKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Host, String) -> Void)? = nil
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

    /// Set by `SessionTabsView`: opens a terminal tab and executes an AI agent `tmux` launch/attach command.
    var launchAIAgent: (@MainActor (Host, AIAgentLaunchContext, String) -> Void)? {
        get { self[LaunchAIAgentKey.self] }
        set { self[LaunchAIAgentKey.self] = newValue }
    }

    /// Set by `SessionTabsView`: opens an interactive terminal tab for `Host` and executes a one-shot shell command.
    var runTerminalCommand: (@MainActor (Host, String) -> Void)? {
        get { self[RunTerminalCommandKey.self] }
        set { self[RunTerminalCommandKey.self] = newValue }
    }
}
