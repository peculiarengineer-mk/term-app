import SwiftUI
import SwiftData
import UIKit
import SSHKit
import Store
import TermUI

/// Reusable live status dot for tabs, switcher rows, and connected host rows.
struct ConnectionStatusDot: View {
    let status: LiveSession.ConnectionStatus
    var size: CGFloat = 7
    var glow: Bool = false

    private var color: Color {
        switch status {
        case .connected: .green
        case .reconnecting: .orange
        case .disconnected: .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.65) : .clear, radius: glow ? 3 : 0)
            .accessibilityHidden(true)
    }
}

/// Floating frosted-glass pill docked above the tab bar when viewing Hosts/Keys/Settings with open or resumable sessions.
struct ActiveSessionPill: View {
    enum Mode {
        case live(
            title: String,
            status: LiveSession.ConnectionStatus,
            agentActivityState: AgentActivityState,
            totalCount: Int,
            showSwitcher: Bool,
            onSwitch: () -> Void
        )
        case resumable(
            agentName: String,
            agentSymbol: String,
            agentTint: Color,
            subtitle: String,
            onDismiss: () -> Void
        )
    }

    let mode: Mode
    let isDark: Bool
    let onResume: () -> Void

    init(
        title: String,
        status: LiveSession.ConnectionStatus,
        agentActivityState: AgentActivityState = .idle,
        totalCount: Int,
        showSwitcher: Bool,
        isDark: Bool,
        onResume: @escaping () -> Void,
        onSwitch: @escaping () -> Void
    ) {
        self.mode = .live(
            title: title,
            status: status,
            agentActivityState: agentActivityState,
            totalCount: totalCount,
            showSwitcher: showSwitcher,
            onSwitch: onSwitch
        )
        self.isDark = isDark
        self.onResume = onResume
    }

    init(
        agentName: String,
        agentSymbol: String,
        agentTint: Color,
        subtitle: String,
        isDark: Bool,
        onResume: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = .resumable(
            agentName: agentName,
            agentSymbol: agentSymbol,
            agentTint: agentTint,
            subtitle: subtitle,
            onDismiss: onDismiss
        )
        self.isDark = isDark
        self.onResume = onResume
    }

    private var needsApproval: Bool {
        if case .live(_, _, let agentActivityState, _, _, _) = mode,
           case .waitingForApproval = agentActivityState {
            return true
        }
        return false
    }

    private var hasTrailingButton: Bool {
        switch mode {
        case .live(_, _, _, _, let showSwitcher, _): showSwitcher
        case .resumable: true
        }
    }

    private var accessibilityLabelText: String {
        switch mode {
        case .live(let title, _, _, _, _, _):
            "Active session: \(title)"
        case .resumable(let agentName, _, _, let subtitle, _):
            "Resume \(agentName), \(subtitle)"
        }
    }

    private var accessibilityValueText: String {
        switch mode {
        case .live(_, let status, _, _, _, _):
            status.accessibilityLabel
        case .resumable:
            "Reattach"
        }
    }

    private var strokeGradient: LinearGradient {
        if needsApproval {
            let amber = AgentVisuals.appleProAmber.opacity(isDark ? 0.65 : 0.72)
            return LinearGradient(colors: [amber, amber.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(isDark ? 0.24 : 0.65),
                Color.white.opacity(isDark ? 0.06 : 0.18),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 10) {
            Button(action: onResume) {
                HStack(spacing: 10) {
                    leadingIcon

                    VStack(alignment: .leading, spacing: 1) {
                        textContent
                    }

                    Spacer(minLength: 4)

                    if !hasTrailingButton {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .padding(.trailing, hasTrailingButton ? 4 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(accessibilityValueText)

            trailingActionButton
        }
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(strokeGradient, lineWidth: needsApproval ? 1 : 0.5))
        .shadow(color: Color.black.opacity(isDark ? 0.42 : 0.14), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch mode {
        case .live(_, let status, _, _, _, _):
            ConnectionStatusDot(status: status, size: 8, glow: true)
        case .resumable(_, let agentSymbol, let agentTint, _, _):
            ProSquircleIcon(
                symbolName: agentSymbol,
                tint: agentTint,
                size: .compact,
                isDark: isDark
            )
        }
    }

    @ViewBuilder
    private var textContent: some View {
        switch mode {
        case .live(let title, _, let agentActivityState, let totalCount, _, _):
            HStack(spacing: 6) {
                Text("Active Session")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                AgentActivityBadge(state: agentActivityState, showLabel: true)
            }

            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if totalCount > 1 {
                    Text("· \(totalCount) open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

        case .resumable(let agentName, _, let agentTint, let subtitle, _):
            HStack(spacing: 6) {
                Text("Resume \(agentName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Reattach")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(agentTint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(agentTint.opacity(isDark ? 0.18 : 0.12), in: Capsule())
                    .fixedSize()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var trailingActionButton: some View {
        switch mode {
        case .live(_, _, _, let totalCount, let showSwitcher, let onSwitch):
            if showSwitcher {
                Button(action: onSwitch) {
                    Image(systemName: "square.on.square")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .minTapTarget()
                        .background(
                            Color.primary.opacity(isDark ? 0.08 : 0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel("Switch sessions (\(totalCount) open)")
            }

        case .resumable(_, _, _, _, let onDismiss):
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .minTapTarget()
                    .background(
                        Color.primary.opacity(isDark ? 0.08 : 0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .accessibilityLabel("Dismiss resumable session")
        }
    }
}

/// The window's content: tabs for its sessions, with the host list as the "new tab" screen.
struct SessionTabsView<HostList: View>: View {
    struct PendingConnection: Identifiable {
        let id: UUID
        let host: Host
        let title: String
        let model: HostConnectionModel
        let aiAgentContext: AIAgentLaunchContext?
        let pendingLaunchCommand: String?
    }

    private enum TabEntry: Identifiable {
        case live(LiveSession)
        case pending(PendingConnection)

        var id: UUID {
            switch self {
            case .live(let live): live.id
            case .pending(let pending): pending.id
            }
        }
    }

    let onFocusHosts: () -> Void
    let onFocusAgents: () -> Void
    @ViewBuilder let hostList: (ActiveSessionPill?) -> HostList
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var manager
    @Environment(AppLockManager.self) private var appLock
    @Environment(ProStore.self) private var proStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage(AppearanceSettings.fontSizeKey) private var fontSize = AppearanceSettings.defaultFontSize
    @Query(sort: \Host.label) private var hosts: [Host]

    init(
        onFocusHosts: @escaping () -> Void = {},
        onFocusAgents: @escaping () -> Void = {},
        @ViewBuilder hostList: @escaping (ActiveSessionPill?) -> HostList
    ) {
        self.onFocusHosts = onFocusHosts
        self.onFocusAgents = onFocusAgents
        self.hostList = hostList
    }
    /// Lives as long as this view. If iOS rebuilds a disconnected scene, its sessions stay open and
    /// are reachable from the switcher (accepted for M1).
    @State private var windowID = UUID()
    @State private var tabOrder: [UUID] = []
    @State private var pendingConnections: [PendingConnection] = []
    /// nil shows the top-level TabView (Hosts / Keys / Settings).
    @State private var selection: UUID?
    @State private var lastSelectedID: UUID?
    @State private var scene: UIWindowScene?
    @State private var switching = false
    @State private var inspectingSecurity: SecurityInspection?
    @State private var activeToolSheet: SessionToolSheet?
    @State private var closingTab: LiveSession?
    @State private var splitState = SplitPaneState()
    @State private var splitPickerRequest: SplitPickerRequest?

    private struct SecurityInspection: Identifiable {
        let id: UUID
        let title: String
        let algorithms: NegotiatedAlgorithms
    }

    private struct SplitPickerRequest: Identifiable {
        let id = UUID()
        let axis: SplitPaneState.SplitAxis
    }

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var windowLiveSessions: [LiveSession] {
        manager.sessions.filter { $0.windowID == windowID }
    }

    private var tabEntries: [TabEntry] {
        let liveByID = Dictionary(uniqueKeysWithValues: windowLiveSessions.map { ($0.id, $0) })
        let pendingByID = Dictionary(uniqueKeysWithValues: pendingConnections.map { ($0.id, $0) })
        return tabOrder.compactMap { id in
            if let live = liveByID[id] { return .live(live) }
            if let pending = pendingByID[id] { return .pending(pending) }
            return nil
        }
    }

    private var selectedLive: LiveSession? {
        guard let selection else { return nil }
        return windowLiveSessions.first(where: { $0.id == selection })
    }

    private var selectedPending: PendingConnection? {
        guard let selection else { return nil }
        return pendingConnections.first(where: { $0.id == selection })
    }

    private var secondaryLive: LiveSession? {
        guard horizontalSizeClass == .regular,
              let primary = selectedLive,
              let secondaryID = splitState.secondarySessionID,
              secondaryID != primary.id else {
            return nil
        }
        return windowLiveSessions.first(where: { $0.id == secondaryID })
    }

    private var secondaryPending: PendingConnection? {
        guard horizontalSizeClass == .regular,
              let primary = selectedLive,
              let secondaryID = splitState.secondarySessionID,
              secondaryID != primary.id else {
            return nil
        }
        return pendingConnections.first(where: { $0.id == secondaryID })
    }

    private var isSplitVisible: Bool {
        selectedLive != nil && (secondaryLive != nil || secondaryPending != nil)
    }

    private var focusedLive: LiveSession? {
        guard let primary = selectedLive else { return nil }
        if isSplitVisible, splitState.focusedPane == .secondary, let secondary = secondaryLive {
            return secondary
        }
        return primary
    }

    private var focusedTabID: UUID? {
        if isSplitVisible, splitState.focusedPane == .secondary {
            return secondaryLive?.id ?? secondaryPending?.id ?? selection
        }
        return selection
    }

    private var orderedWindowLiveSessions: [LiveSession] {
        let byID = Dictionary(uniqueKeysWithValues: windowLiveSessions.map { ($0.id, $0) })
        var ordered = tabOrder.compactMap { byID[$0] }
        let seen = Set(ordered.map(\.id))
        for live in windowLiveSessions where !seen.contains(live.id) {
            ordered.append(live)
        }
        return ordered
    }

    private var isTerminalActive: Bool {
        selectedLive != nil || selectedPending != nil
    }

    private var canOpenInNewWindow: Bool {
        UIApplication.shared.supportsMultipleScenes && horizontalSizeClass == .regular
    }

    private var isModalOverSelectedTerminal: Bool {
        activeToolSheet != nil || switching || inspectingSecurity != nil || splitPickerRequest != nil
    }

    private var activeSessionPill: ActiveSessionPill? {
        guard selection == nil else {
            return nil
        }

        if manager.sessions.isEmpty && pendingConnections.isEmpty {
            let _ = manager.cacheRevision
            guard proStore.isProUnlocked,
                  let resumable = resumableCachedSessionForSavedHost(),
                  let host = hosts.first(where: { $0.id == resumable.hostID }) else {
                return nil
            }
            return makeResumableSessionPill(for: resumable, host: host)
        }

        let waitingForApprovalSession: LiveSession? = {
            if let lastSelectedID,
               let lastLive = manager.session(id: lastSelectedID),
               case .waitingForApproval = lastLive.agentActivityState {
                return lastLive
            }
            return manager.sessions.first {
                if case .waitingForApproval = $0.agentActivityState { return true }
                return false
            }
        }()

        let matchedByLastID: TabEntry? = lastSelectedID.flatMap { id in
            if let live = manager.session(id: id) { return .live(live) }
            if let pending = pendingConnections.first(where: { $0.id == id }) { return .pending(pending) }
            return nil
        }
        let target: TabEntry? = waitingForApprovalSession.map(TabEntry.live)
            ?? matchedByLastID
            ?? manager.sessions.last.map(TabEntry.live)
            ?? pendingConnections.last.map(TabEntry.pending)

        let totalCount = manager.sessions.count + pendingConnections.count
        let showSwitcher = totalCount > 1

        switch target {
        case .live(let live):
            return ActiveSessionPill(
                title: live.title,
                status: live.connectionStatus,
                agentActivityState: live.agentActivityState,
                totalCount: totalCount,
                showSwitcher: showSwitcher,
                isDark: theme.isDark,
                onResume: {
                    AppHaptics.impact(.light)
                    addTab(live.id)
                },
                onSwitch: {
                    AppHaptics.impact(.light)
                    switching = true
                }
            )
        case .pending(let pending):
            let title = pending.model.title.isEmpty ? pending.title : pending.model.title
            return ActiveSessionPill(
                title: title,
                status: pendingStatus(for: pending.model.phase),
                totalCount: totalCount,
                showSwitcher: showSwitcher,
                isDark: theme.isDark,
                onResume: {
                    AppHaptics.impact(.light)
                    selection = pending.id
                },
                onSwitch: {
                    AppHaptics.impact(.light)
                    switching = true
                }
            )
        case nil:
            return nil
        }
    }

    private func resumableCachedSessionForSavedHost() -> CachedAISession? {
        let hostIDs = Set(hosts.map(\.id))
        guard !hostIDs.isEmpty else { return nil }
        if let latest = AISessionCacheStore.lastOpenSession(defaults: manager.cacheDefaults),
           hostIDs.contains(latest.hostID) {
            return latest
        }
        return AISessionCacheStore.openInAppSessions(defaults: manager.cacheDefaults)
            .first { hostIDs.contains($0.hostID) }
    }

    private func makeResumableSessionPill(for resumable: CachedAISession, host: Host) -> ActiveSessionPill {
        let descriptor = AgentVisuals.agentDescriptor(forSlug: resumable.agentSlug)
        let hostTitle = host.label.isEmpty ? host.hostname : host.label
        let project: String = {
            if !resumable.projectSlug.isEmpty {
                return resumable.projectSlug
            }
            if let path = resumable.currentPath, !path.isEmpty {
                return path
            }
            return resumable.sessionName
        }()
        let subtitle = "\(hostTitle) · \(project)"
        let workingDirectory = resumable.currentPath ?? "~"

        return ActiveSessionPill(
            agentName: descriptor.name,
            agentSymbol: AgentVisuals.agentSymbol(for: descriptor),
            agentTint: AgentVisuals.agentTint(for: descriptor),
            subtitle: subtitle,
            isDark: theme.isDark,
            onResume: {
                AppHaptics.impact(.light)
                let context = AIAgentLaunchContext(
                    agent: descriptor,
                    sessionName: resumable.sessionName,
                    workingDirectory: workingDirectory,
                    hostID: host.id,
                    isTmuxBacked: true
                )
                let command = TMuxSessionHelper.attachCommand(sessionName: resumable.sessionName)
                launchAIAgent(host: host, context: context, command: command)
            },
            onDismiss: {
                AppHaptics.impact(.light)
                AISessionCacheStore.markOpenInApp(
                    false,
                    hostID: resumable.hostID,
                    sessionName: resumable.sessionName,
                    defaults: manager.cacheDefaults
                )
                manager.noteCacheChanged()
            }
        )
    }

    var body: some View {
        withModalPresentations(withWindowAndNotificationLifecycle(withSplitAndSelectionLifecycle(mainTabsContent)))
    }

    private var mainTabsContent: some View {
        VStack(spacing: 0) {
            if selectedLive != nil || selectedPending != nil {
                tabBar
            }
            if let live = selectedLive {
                if isSplitVisible {
                    splitWorkspace(primary: live)
                } else {
                    TerminalPane(
                        live: live,
                        onOpenGitDiff: { openGitDiffShortcut() },
                        onOpenDevPreview: { openDevServerPreviewShortcut() }
                    )
                }
            } else if let pending = selectedPending {
                HostConnectionView(
                    host: pending.host,
                    model: pending.model,
                    onConnected: { _ in },
                    onCancel: { cancelPending(pending.id) }
                )
                .id(pending.id)
            } else {
                hostList(activeSessionPill)
            }
        }
        .environment(\.openSessionTab) { id in addTab(id) }
        .environment(\.connectHost) { host in connectHost(host) }
        .environment(\.launchAIAgent) { host, context, command in
            launchAIAgent(host: host, context: context, command: command)
        }
        .environment(\.runTerminalCommand) { host, command in
            connectHost(host, pendingLaunchCommand: command)
        }
        .background(SceneReader(scene: $scene))
        .background {
            if let scene, !appLock.isLocked {
                TabNotifications(
                    scene: scene,
                    onNewTab: { newTab() },
                    onCloseTab: { closeCurrent() },
                    onSwitchTab: { switchTab($0) }
                )
            }
        }
        .background { keyboardShortcutsLayer }
    }

    private func withSplitAndSelectionLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                if let newSelection {
                    lastSelectedID = newSelection
                }
                reconcileSplitState()
                syncModalPresentationState()
            }
            .onChange(of: selectedLive?.id) { oldID, newID in
                if let oldID, oldID != newID {
                    manager.session(id: oldID)?.hasModalSheetPresented = false
                }
                syncModalPresentationState()
            }
            .onChange(of: secondaryLive?.id) { oldID, newID in
                if let oldID, oldID != newID {
                    manager.session(id: oldID)?.hasModalSheetPresented = false
                }
                syncModalPresentationState()
            }
            .onChange(of: horizontalSizeClass) { _, _ in
                syncModalPresentationState()
            }
            .onChange(of: isModalOverSelectedTerminal) { _, _ in
                syncModalPresentationState()
            }
            .onChange(of: splitState.secondarySessionID) { _, _ in
                reconcileSplitState()
                syncModalPresentationState()
            }
    }

    private func withWindowAndNotificationLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: windowLiveSessions.map(\.id)) { _, liveIDs in
                let liveSet = Set(liveIDs)
                let pendingSet = Set(pendingConnections.map(\.id))
                tabOrder.removeAll { !liveSet.contains($0) && !pendingSet.contains($0) }
                if let s = selection, !tabOrder.contains(s) {
                    selection = tabOrder.last
                }
                reconcileSplitState()
                syncModalPresentationState()
            }
            .onChange(of: pendingConnections.map(\.id)) { _, _ in
                reconcileSplitState()
            }
            .onAppear {
                reconcileSplitState()
                syncModalPresentationState()
                consumeAndFocusPendingAgentSessionIfUnlocked()
                consumePendingDeepLinkIfUnlocked()
                consumePendingMergeBackIfNeeded()
                consumePendingNewTabIfNeeded()
            }
            .onDisappear {
                for live in windowLiveSessions {
                    live.hasModalSheetPresented = false
                }
            }
            .onChange(of: manager.pendingMergeBackSessionID) { _, _ in
                consumePendingMergeBackIfNeeded()
            }
            .onChange(of: manager.pendingNewTabRequestID) { _, _ in
                consumePendingNewTabIfNeeded()
            }
            .onChange(of: appLock.isLocked) { _, isLocked in
                if !isLocked {
                    consumeAndFocusPendingAgentSessionIfUnlocked()
                    consumePendingDeepLinkIfUnlocked()
                }
            }
            .onChange(of: DeepLinkRouter.shared.pendingLink) { _, _ in
                consumePendingDeepLinkIfUnlocked()
            }
            .onReceive(NotificationCenter.default.publisher(for: .termFocusAgentSession)) { note in
                if let id = note.userInfo?[AgentNotificationManager.sessionIDKey] as? UUID {
                    focusAgentSessionIfUnlocked(id)
                }
            }
    }

    private func withModalPresentations<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $switching) {
                SessionSwitcher(
                    selectedID: selection,
                    onSelect: { addTab($0) },
                    onOpenInWindow: { moveToWindow($0) }
                )
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
            }
            .sheet(item: $splitPickerRequest) { request in
                SplitPanePickerSheet(
                    axis: request.axis,
                    primarySessionID: selection,
                    currentWindowID: windowID,
                    theme: theme,
                    onSelectSession: { sessionID in
                        splitWithExistingSession(sessionID, axis: request.axis)
                    },
                    onConnectHost: { host in
                        connectHost(host, splitAxis: request.axis)
                    }
                )
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
            }
            .sessionToolSheets(item: $activeToolSheet, theme: theme)
            .confirmationDialog(
                "Close active session?",
                isPresented: Binding(get: { closingTab != nil }, set: { if !$0 { closingTab = nil } }),
                titleVisibility: .visible,
                presenting: closingTab
            ) { live in
                if live.ephemeralHost != nil {
                    Button("Save Host", systemImage: "bookmark.badge.plus") {
                        manager.saveEphemeralHost(for: live.id, in: modelContext)
                    }
                }
                Button("Close Session", role: .destructive) {
                    AppHaptics.impact(.light)
                    manager.close(live.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { live in
                Text("Closing \"\(live.title)\" will disconnect the active SSH session.")
            }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if tabEntries.isEmpty {
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tabEntries) { entry in
                                    switch entry {
                                    case .live(let live):
                                        liveTabChip(for: live)
                                            .id(live.id)
                                    case .pending(let pending):
                                        pendingTabChip(for: pending)
                                            .id(pending.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .onChange(of: selection) { _, newSelection in
                            guard let newSelection else { return }
                            if reduceMotion {
                                proxy.scrollTo(newSelection, anchor: .center)
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(newSelection, anchor: .center)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 2) {
                    if let activeLive = focusedLive {
                        SessionToolsMenu(
                            live: activeLive,
                            isProUnlocked: proStore.isProUnlocked,
                            foregroundColor: theme.foregroundColor
                        ) { tool in
                            activeToolSheet = tool
                        }
                    }

                    if horizontalSizeClass == .regular, selectedLive != nil {
                        splitMenuButton
                    }

                    if horizontalSizeClass != .compact, let activeLive = focusedLive, let algorithms = activeLive.algorithms {
                        Button {
                            AppHaptics.impact(.light)
                            inspectingSecurity = SecurityInspection(
                                id: activeLive.id,
                                title: activeLive.title,
                                algorithms: algorithms
                            )
                        } label: {
                            Image(systemName: algorithms.isPostQuantum ? "lock.shield.fill" : "lock.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(algorithms.isPostQuantum ? Color.green : Color.orange)
                                .minTapTarget()
                        }
                        .accessibilityLabel(algorithms.isPostQuantum ? "Connection security: Post-quantum" : "Connection security: Classical")
                        .popover(item: $inspectingSecurity) { item in
                            ConnectionSecuritySheet(title: item.title, algorithms: item.algorithms)
                                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                        }
                    }

                    if !tabEntries.isEmpty && selection != nil {
                        Button {
                            AppHaptics.impact(.light)
                            selection = nil
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.foregroundColor)
                                .minTapTarget()
                        }
                        .accessibilityLabel("Back to Workspace")
                    }

                    Button {
                        AppHaptics.impact(.light)
                        switching = true
                    } label: {
                        Image(systemName: "square.on.square")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.foregroundColor)
                            .minTapTarget()
                    }
                    .accessibilityLabel("Sessions")
                }
                .padding(.trailing, 4)
            }
            .padding(.vertical, 4)

            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12))
                .frame(height: 0.5)
        }
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.82)
                Rectangle().fill(.ultraThinMaterial)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func liveTabChip(for live: LiveSession) -> some View {
        let isSelected = selection == live.id
        let isSecondaryPane = isSplitVisible && splitState.secondarySessionID == live.id
        return HStack(spacing: 4) {
            Button {
                AppHaptics.impact(.light)
                selection = live.id
            } label: {
                HStack(spacing: 6) {
                    ConnectionStatusDot(status: live.connectionStatus)
                    if isSecondaryPane {
                        Image(systemName: splitState.axis == .horizontal ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.accentColor)
                            .accessibilityHidden(true)
                    }
                    if let ai = live.aiAgentContext {
                        Image(systemName: AgentVisuals.agentSymbol(for: ai.agent))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AgentVisuals.agentTint(for: ai.agent))
                            .accessibilityHidden(true)
                    }
                    Text(live.title)
                        .lineLimit(1)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    AgentActivityBadge(state: live.agentActivityState)
                }
                .padding(.vertical, isSelected ? 6 : 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live.title)
            .accessibilityValue(live.connectionStatus.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                Button {
                    requestCloseLive(live)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(live.title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected ? 2 : 12)
        .padding(.vertical, isSelected ? 0 : 1)
        .foregroundStyle(isSelected ? theme.foregroundColor : theme.secondaryForegroundColor)
        .background(
            isSelected
                ? theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16)
                : theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected
                        ? theme.accentColor.opacity(0.45)
                        : (isSecondaryPane ? theme.accentColor.opacity(0.30) : Color.clear),
                    lineWidth: 1
                )
        )
        .contextMenu {
            if live.ephemeralHost != nil {
                Button("Save Host", systemImage: "bookmark.badge.plus") {
                    manager.saveEphemeralHost(for: live.id, in: modelContext)
                }
            }
            if canOpenInNewWindow {
                Button("Move to New Window", systemImage: "macwindow.badge.plus") { moveToWindow(live.id) }
            }
            Button("Close", systemImage: "xmark", role: .destructive) {
                requestCloseLive(live)
            }
        }
    }

    private func pendingTabChip(for pending: PendingConnection) -> some View {
        let isSelected = selection == pending.id
        let isSecondaryPane = isSplitVisible && splitState.secondarySessionID == pending.id
        let chipTitle = pending.model.title.isEmpty ? pending.title : pending.model.title
        let dotStatus = pendingStatus(for: pending.model.phase)
        let statusValue = dotStatus == .disconnected ? "Connection error" : "Connecting"

        return HStack(spacing: 4) {
            Button {
                AppHaptics.impact(.light)
                selection = pending.id
            } label: {
                HStack(spacing: 6) {
                    ConnectionStatusDot(status: dotStatus)
                    if isSecondaryPane {
                        Image(systemName: splitState.axis == .horizontal ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.accentColor)
                            .accessibilityHidden(true)
                    }
                    Text(chipTitle)
                        .lineLimit(1)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                }
                .padding(.vertical, isSelected ? 6 : 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chipTitle)
            .accessibilityValue(statusValue)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                Button {
                    AppHaptics.impact(.light)
                    cancelPending(pending.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(chipTitle)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected ? 2 : 12)
        .padding(.vertical, isSelected ? 0 : 1)
        .foregroundStyle(isSelected ? theme.foregroundColor : theme.secondaryForegroundColor)
        .background(
            isSelected
                ? theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16)
                : theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected
                        ? theme.accentColor.opacity(0.45)
                        : (isSecondaryPane ? theme.accentColor.opacity(0.30) : Color.clear),
                    lineWidth: 1
                )
        )
        .contextMenu {
            Button("Close", systemImage: "xmark", role: .destructive) {
                AppHaptics.impact(.light)
                cancelPending(pending.id)
            }
        }
    }

    private func pendingStatus(for phase: HostConnectionModel.Phase) -> LiveSession.ConnectionStatus {
        switch phase {
        case .failed, .mismatch, .keyMissing:
            return .disconnected
        case .connecting, .input, .prompt, .connected:
            return .reconnecting
        }
    }

    func launchAIAgent(host: Host, context: AIAgentLaunchContext, command: String) {
        connectHost(host, aiAgentContext: context, pendingLaunchCommand: command)
    }

    func connectHost(
        _ host: Host,
        aiAgentContext: AIAgentLaunchContext? = nil,
        pendingLaunchCommand: String? = nil,
        splitAxis: SplitPaneState.SplitAxis? = nil
    ) {
        let pendingID = UUID()
        let hostTitle = host.label.isEmpty ? host.hostname : host.label
        let title = aiAgentContext.map { "\($0.agent.name) · \(hostTitle)" } ?? hostTitle
        let model = HostConnectionModel(host: host)
        let pending = PendingConnection(
            id: pendingID,
            host: host,
            title: title,
            model: model,
            aiAgentContext: aiAgentContext,
            pendingLaunchCommand: pendingLaunchCommand
        )
        pendingConnections.append(pending)
        tabOrder.append(pendingID)
        if let splitAxis, horizontalSizeClass == .regular, selection != nil {
            splitState.split(with: pendingID, axis: splitAxis)
        } else {
            selection = pendingID
        }

        model.onConnected = { [weak model] conn, bridge in
            defer { model?.onConnected = nil }
            guard let model, pendingConnections.contains(where: { $0.id == pendingID }) else {
                Task { await conn.close() }
                return
            }
            let resolvedHostTitle = model.title.isEmpty ? hostTitle : model.title
            let resolvedTitle = aiAgentContext.map { "\($0.agent.name) · \(resolvedHostTitle)" } ?? resolvedHostTitle
            let live = manager.open(
                hostID: host.id,
                title: resolvedTitle,
                session: conn,
                bridge: bridge,
                ephemeralHost: host.modelContext == nil ? host : nil,
                aiAgentContext: aiAgentContext,
                pendingLaunchCommand: pendingLaunchCommand
            ) // wiring: T8
            if aiAgentContext == nil && pendingLaunchCommand == nil {
                TmuxAttach.send(model.tmux, via: bridge) // wiring: T9
            }
            completePending(pendingID, liveID: live.id)
            live.dispatchPendingLaunchCommandIfReady()
        }
        model.start()
    }

    private func completePending(_ pendingID: UUID, liveID: UUID) {
        pendingConnections.removeAll { $0.id == pendingID }
        manager.show(liveID, in: windowID)
        if let index = tabOrder.firstIndex(of: pendingID) {
            tabOrder[index] = liveID
        } else if !tabOrder.contains(liveID) {
            tabOrder.append(liveID)
        }
        if selection == pendingID {
            selection = liveID
        }
        if splitState.secondarySessionID == pendingID {
            splitState.secondarySessionID = liveID
        }
        if lastSelectedID == pendingID {
            lastSelectedID = liveID
        }
    }

    private func cancelPending(_ pendingID: UUID) {
        if let index = pendingConnections.firstIndex(where: { $0.id == pendingID }) {
            let pending = pendingConnections.remove(at: index)
            pending.model.onConnected = nil
            pending.model.teardown()
        }
        tabOrder.removeAll { $0 == pendingID }
        if selection == pendingID {
            selection = tabOrder.last
        }
        if splitState.secondarySessionID == pendingID {
            splitState.closeSplit()
        }
        if lastSelectedID == pendingID {
            lastSelectedID = nil
        }
        reconcileSplitState()
    }

    private func requestCloseLive(_ live: LiveSession) {
        if live.connectionStatus == .connected {
            AppHaptics.impact(.light)
            closingTab = live
        } else {
            AppHaptics.impact(.light)
            manager.close(live.id)
        }
    }

    func addTab(_ id: UUID) {
        guard manager.session(id: id) != nil else { return }
        if horizontalSizeClass == .regular, splitState.secondarySessionID == id, selectedLive != nil {
            splitState.focusedPane = .secondary
            manager.session(id: id)?.shouldAutoFocus = true
            return
        }
        manager.show(id, in: windowID) // moves it out of any other window
        if !tabOrder.contains(id) { tabOrder.append(id) }
        selection = id
    }

    private func focusAgentSessionIfUnlocked(_ id: UUID) {
        guard !appLock.isLocked else { return }
        _ = AgentNotificationManager.shared.consumePendingFocusSessionID()
        guard manager.session(id: id) != nil else { return }
        addTab(id)
    }

    private func consumeAndFocusPendingAgentSessionIfUnlocked() {
        guard !appLock.isLocked,
              let id = AgentNotificationManager.shared.consumePendingFocusSessionID(),
              manager.session(id: id) != nil else {
            return
        }
        addTab(id)
    }

    private func consumePendingDeepLinkIfUnlocked() {
        guard !appLock.isLocked,
              let link = DeepLinkRouter.shared.consumePendingLink() else {
            return
        }
        handleDeepLink(link)
    }

    private func handleDeepLink(_ link: TermAppDeepLink) {
        switching = false
        splitPickerRequest = nil
        activeToolSheet = nil
        inspectingSecurity = nil

        switch link {
        case .connectHost(let hostID):
            if let host = findHost(id: hostID) {
                connectHost(host)
            } else {
                selection = nil
                onFocusHosts()
            }

        case .focusSession(let sessionID):
            if manager.session(id: sessionID) != nil {
                addTab(sessionID)
                return
            }
            if proStore.isProUnlocked,
               let snapshot = WidgetSnapshotStore.loadAgents().first(where: { $0.sessionID == sessionID }),
               let host = findHost(id: snapshot.hostID),
               AISessionCacheStore.load(defaults: manager.cacheDefaults).contains(where: {
                   $0.hostID == snapshot.hostID && $0.sessionName == snapshot.sessionName
               }) {
                handleDeepLink(
                    .launchAgent(
                        hostID: host.id,
                        agentSlug: snapshot.agentSlug,
                        sessionName: snapshot.sessionName
                    )
                )
                return
            }
            selection = nil
            onFocusAgents()

        case .launchAgent(let hostID, let agentSlug, let sessionName):
            guard proStore.isProUnlocked, let host = findHost(id: hostID) else {
                selection = nil
                onFocusAgents()
                return
            }

            let trimmedSession = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedSession.isEmpty {
                if let existing = manager.sessions.first(where: {
                    $0.hostID == hostID && $0.aiAgentContext?.sessionName == trimmedSession
                }) {
                    addTab(existing.id)
                    return
                }

                let cachedEntry = AISessionCacheStore.load(defaults: manager.cacheDefaults).first {
                    $0.hostID == hostID && $0.sessionName == trimmedSession
                }
                let resolvedSlug = nonEmptyTrimmed(agentSlug)
                    ?? cachedEntry?.agentSlug
                    ?? HostProjectStore.lastAgentID(for: hostID)
                    ?? BuiltInAIAgent.claude.rawValue
                let descriptor = AgentVisuals.agentDescriptor(forSlug: resolvedSlug)
                let workingDirectory = cachedEntry?.currentPath
                    ?? HostProjectStore.recents(for: hostID).first
                    ?? HostProjectStore.favorites(for: hostID).first
                    ?? "~"
                let context = AIAgentLaunchContext(
                    agent: descriptor,
                    sessionName: trimmedSession,
                    workingDirectory: workingDirectory,
                    hostID: host.id
                )
                let command = TMuxSessionHelper.attachCommand(sessionName: trimmedSession)
                launchAIAgent(host: host, context: context, command: command)
                return
            }

            let resolvedSlug = nonEmptyTrimmed(agentSlug)
                ?? HostProjectStore.lastAgentID(for: hostID)
                ?? BuiltInAIAgent.claude.rawValue
            let descriptor = AgentVisuals.agentDescriptor(forSlug: resolvedSlug)
            let workingDirectory = HostProjectStore.recents(for: hostID).first
                ?? HostProjectStore.favorites(for: hostID).first
                ?? "~"
            let computedSessionName = TMuxSessionHelper.sessionName(
                agentSlug: descriptor.slug,
                workingDirectory: workingDirectory
            )

            if let existing = manager.sessions.first(where: {
                $0.hostID == hostID
                    && $0.aiAgentContext?.sessionName == computedSessionName
                    && $0.connectionStatus == .connected
            }) {
                addTab(existing.id)
                return
            }

            HostProjectStore.recordRecent(workingDirectory, for: host.id)
            HostProjectStore.setLastAgentID(descriptor.id, for: host.id)
            let context = AIAgentLaunchContext(
                agent: descriptor,
                sessionName: computedSessionName,
                workingDirectory: workingDirectory,
                hostID: host.id
            )
            let command = TMuxSessionHelper.launchOrAttachCommand(
                agent: descriptor,
                workingDirectory: workingDirectory,
                sessionName: computedSessionName
            )
            launchAIAgent(host: host, context: context, command: command)

        case .openAgentsTab:
            selection = nil
            onFocusAgents()
        }
    }

    private func findHost(id: UUID) -> Host? {
        if let host = hosts.first(where: { $0.id == id }) {
            return host
        }
        var descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func consumePendingMergeBackIfNeeded() {
        guard let id = manager.consumePendingMergeBackSessionID(),
              manager.session(id: id) != nil else {
            return
        }
        addTab(id)
    }

    private func consumePendingNewTabIfNeeded() {
        guard manager.consumePendingNewTabRequestID() != nil else { return }
        newTab()
        if let scene, scene.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
        }
    }

    private func moveToWindow(_ id: UUID) {
        manager.session(id: id)?.hasModalSheetPresented = false
        manager.detach(id)
        tabOrder.removeAll { $0 == id }
        if selection == id { selection = tabOrder.last }
        if splitState.secondarySessionID == id { splitState.closeSplit() }
        if lastSelectedID == id { lastSelectedID = nil }
        openWindow(value: id)
    }

    fileprivate func newTab() {
        AppHaptics.impact(.light)
        selection = nil
        onFocusHosts()
    }

    fileprivate func closeCurrent() {
        guard let targetID = focusedTabID ?? selection else { return }
        if let live = windowLiveSessions.first(where: { $0.id == targetID }) {
            requestCloseLive(live)
        } else if pendingConnections.contains(where: { $0.id == targetID }) {
            AppHaptics.impact(.light)
            cancelPending(targetID)
        }
    }

    fileprivate func switchTab(_ index: Int) {
        let entries = tabEntries
        guard entries.indices.contains(index) else { return }
        let targetID = entries[index].id
        if selection != targetID {
            AppHaptics.impact(.light)
            selection = targetID
        }
    }

    private func adjustFontSize(by delta: Double) {
        fontSize = SessionFontShortcuts.adjustedFontSize(from: fontSize, delta: delta)
        AppHaptics.impact(.light)
    }

    private func resetFontSize() {
        fontSize = AppearanceSettings.defaultFontSize
        AppHaptics.impact(.light)
    }

    private func openGitDiffShortcut() {
        guard activeToolSheet == nil,
              !switching,
              closingTab == nil,
              inspectingSecurity == nil,
              splitPickerRequest == nil,
              let live = focusedLive,
              let sheet = SessionToolSheet.gitDiff(for: live, isProUnlocked: proStore.isProUnlocked) else {
            return
        }
        AppHaptics.impact(.light)
        activeToolSheet = sheet
    }

    private func openDevServerPreviewShortcut() {
        guard activeToolSheet == nil,
              !switching,
              closingTab == nil,
              inspectingSecurity == nil,
              splitPickerRequest == nil,
              let live = focusedLive,
              let sheet = SessionToolSheet.devServerPreview(for: live, isProUnlocked: proStore.isProUnlocked) else {
            return
        }
        AppHaptics.impact(.light)
        activeToolSheet = sheet
    }

    // MARK: - iPad Split Panes

    private var splitMenuButton: some View {
        Menu {
            if isSplitVisible {
                Button {
                    AppHaptics.impact(.light)
                    splitState.toggleAxis()
                } label: {
                    Label(
                        splitState.axis == .horizontal ? "Switch to Top & Bottom" : "Switch to Side-by-Side",
                        systemImage: splitState.axis == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1"
                    )
                }

                Button("Swap Panes", systemImage: "arrow.left.arrow.right") {
                    AppHaptics.impact(.light)
                    var primaryID = selection
                    splitState.swap(primary: &primaryID)
                    selection = primaryID
                }

                Button("Switch Focus", systemImage: "scope") {
                    toggleSplitFocus()
                }

                Button("Change Secondary Pane…", systemImage: "plus.rectangle.on.rectangle") {
                    AppHaptics.impact(.light)
                    splitPickerRequest = SplitPickerRequest(axis: splitState.axis)
                }

                Divider()

                Button("Close Split", systemImage: "xmark.rectangle") {
                    AppHaptics.impact(.light)
                    splitState.closeSplit()
                }
            } else {
                Button("Split Right", systemImage: "rectangle.split.2x1") {
                    triggerSplit(axis: .horizontal, allowCycleWhenSplit: false)
                }

                Button("Split Down", systemImage: "rectangle.split.1x2") {
                    triggerSplit(axis: .vertical, allowCycleWhenSplit: false)
                }

                Divider()

                Button("Pick Session or Host…", systemImage: "plus.rectangle.on.rectangle") {
                    AppHaptics.impact(.light)
                    splitPickerRequest = SplitPickerRequest(axis: .horizontal)
                }
            }
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSplitVisible ? theme.accentColor : theme.foregroundColor)
                .minTapTarget()
        }
        .accessibilityLabel(isSplitVisible ? "Split Pane Options" : "Split Pane")
    }

    @ViewBuilder
    private func splitWorkspace(primary: LiveSession) -> some View {
        GeometryReader { proxy in
            let dividerThickness = DraggableSplitDivider.thickness
            let totalLength = splitState.axis == .horizontal ? proxy.size.width : proxy.size.height
            let availableLength = max(0, totalLength - dividerThickness)
            let primaryLength = availableLength * splitState.ratio
            let secondaryLength = max(0, availableLength - primaryLength)

            if splitState.axis == .horizontal {
                HStack(spacing: 0) {
                    primarySplitPane(primary)
                        .frame(width: primaryLength, height: proxy.size.height)

                    DraggableSplitDivider(
                        axis: .horizontal,
                        ratio: $splitState.ratio,
                        totalLength: proxy.size.width,
                        theme: theme
                    )

                    secondarySplitPane()
                        .frame(width: secondaryLength, height: proxy.size.height)
                }
            } else {
                VStack(spacing: 0) {
                    primarySplitPane(primary)
                        .frame(width: proxy.size.width, height: primaryLength)

                    DraggableSplitDivider(
                        axis: .vertical,
                        ratio: $splitState.ratio,
                        totalLength: proxy.size.height,
                        theme: theme
                    )

                    secondarySplitPane()
                        .frame(width: proxy.size.width, height: secondaryLength)
                }
            }
        }
        .padding(4)
        .background(theme.backgroundColor)
    }

    private func primarySplitPane(_ primary: LiveSession) -> some View {
        let isFocused = splitState.focusedPane == .primary
        return splitPaneContainer(
            pane: .primary,
            title: primary.title,
            status: primary.connectionStatus,
            agentContext: primary.aiAgentContext,
            agentActivity: primary.agentActivityState,
            isFocused: isFocused
        ) {
            TerminalPane(
                live: primary,
                isFocusedPane: isFocused,
                onFocusPane: { focusPane(.primary) },
                onOpenGitDiff: {
                    focusPane(.primary)
                    openGitDiffShortcut()
                },
                onOpenDevPreview: {
                    focusPane(.primary)
                    openDevServerPreviewShortcut()
                }
            )
        }
    }

    @ViewBuilder
    private func secondarySplitPane() -> some View {
        let isFocused = splitState.focusedPane == .secondary
        if let secondary = secondaryLive {
            splitPaneContainer(
                pane: .secondary,
                title: secondary.title,
                status: secondary.connectionStatus,
                agentContext: secondary.aiAgentContext,
                agentActivity: secondary.agentActivityState,
                isFocused: isFocused
            ) {
                TerminalPane(
                    live: secondary,
                    isFocusedPane: isFocused,
                    onFocusPane: { focusPane(.secondary) },
                    onOpenGitDiff: {
                        focusPane(.secondary)
                        openGitDiffShortcut()
                    },
                    onOpenDevPreview: {
                        focusPane(.secondary)
                        openDevServerPreviewShortcut()
                    }
                )
            }
        } else if let pending = secondaryPending {
            let pendingTitle = pending.model.title.isEmpty ? pending.title : pending.model.title
            splitPaneContainer(
                pane: .secondary,
                title: pendingTitle,
                status: pendingStatus(for: pending.model.phase),
                agentContext: pending.aiAgentContext,
                agentActivity: .idle,
                isFocused: isFocused
            ) {
                HostConnectionView(
                    host: pending.host,
                    model: pending.model,
                    onConnected: { _ in },
                    onCancel: { cancelPending(pending.id) }
                )
                .id(pending.id)
            }
        }
    }

    private func splitPaneContainer<Content: View>(
        pane: SplitPaneState.SplitFocus,
        title: String,
        status: LiveSession.ConnectionStatus,
        agentContext: AIAgentLaunchContext?,
        agentActivity: AgentActivityState,
        isFocused: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let cornerRadius: CGFloat = 6
        return VStack(spacing: 0) {
            splitPaneHeader(
                pane: pane,
                title: title,
                status: status,
                agentContext: agentContext,
                agentActivity: agentActivity,
                isFocused: isFocused
            )

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? theme.accentColor.opacity(0.85) : palette.borderSubtle,
                    lineWidth: isFocused ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                focusPane(pane)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityValue(isFocused ? "Focused pane" : "Inactive pane")
    }

    private func splitPaneHeader(
        pane: SplitPaneState.SplitFocus,
        title: String,
        status: LiveSession.ConnectionStatus,
        agentContext: AIAgentLaunchContext?,
        agentActivity: AgentActivityState,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 6) {
            ConnectionStatusDot(status: status, size: 6, glow: isFocused)

            if let ai = agentContext {
                Image(systemName: AgentVisuals.agentSymbol(for: ai.agent))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentVisuals.agentTint(for: ai.agent))
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.caption.weight(isFocused ? .semibold : .medium))
                .foregroundStyle(isFocused ? theme.foregroundColor : theme.secondaryForegroundColor)
                .lineLimit(1)

            AgentActivityBadge(state: agentActivity)

            Spacer(minLength: 4)

            Button {
                AppHaptics.impact(.light)
                unsplitKeepingOther(closing: pane)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title) split pane")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(
            isFocused
                ? theme.accentColor.opacity(theme.isDark ? 0.14 : 0.10)
                : theme.foregroundColor.opacity(theme.isDark ? 0.04 : 0.03)
        )
        .background(theme.backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusPane(pane)
        }
    }

    private func focusPane(_ pane: SplitPaneState.SplitFocus) {
        if splitState.focusedPane != pane {
            splitState.focusedPane = pane
        }
    }

    private func toggleSplitFocus() {
        guard isSplitVisible else { return }
        AppHaptics.impact(.light)
        splitState.toggleFocus()
        focusedLive?.shouldAutoFocus = true
    }

    private func unsplitKeepingOther(closing pane: SplitPaneState.SplitFocus) {
        if pane == .primary, let secondaryID = splitState.secondarySessionID {
            selection = secondaryID
        }
        splitState.closeSplit()
    }

    private func triggerSplit(axis: SplitPaneState.SplitAxis, allowCycleWhenSplit: Bool) {
        guard horizontalSizeClass == .regular, let primary = selectedLive else { return }
        let candidates = orderedWindowLiveSessions.filter { $0.id != primary.id }

        if isSplitVisible {
            guard allowCycleWhenSplit else { return }
            AppHaptics.impact(.light)
            if splitState.axis != axis {
                splitState.axis = axis
                return
            }
            if candidates.count > 1,
               let currentID = splitState.secondarySessionID,
               let idx = candidates.firstIndex(where: { $0.id == currentID }) {
                let next = candidates[(idx + 1) % candidates.count]
                splitState.split(with: next.id, axis: axis)
                next.shouldAutoFocus = true
            } else {
                splitPickerRequest = SplitPickerRequest(axis: axis)
            }
            return
        }

        AppHaptics.impact(.light)
        if let target = candidates.first {
            splitState.split(with: target.id, axis: axis)
            target.shouldAutoFocus = true
        } else {
            splitPickerRequest = SplitPickerRequest(axis: axis)
        }
    }

    private func splitWithExistingSession(_ sessionID: UUID, axis: SplitPaneState.SplitAxis) {
        guard horizontalSizeClass == .regular,
              let primaryID = selection,
              sessionID != primaryID,
              manager.session(id: sessionID) != nil else {
            return
        }
        manager.show(sessionID, in: windowID)
        if !tabOrder.contains(sessionID) {
            tabOrder.append(sessionID)
        }
        splitState.split(with: sessionID, axis: axis)
        manager.session(id: sessionID)?.shouldAutoFocus = true
    }

    private func handleBracketShortcut(forward: Bool) {
        guard horizontalSizeClass == .regular else { return }
        if isSplitVisible {
            toggleSplitFocus()
            return
        }
        let entries = tabEntries
        guard entries.count > 1,
              let current = selection,
              let idx = entries.firstIndex(where: { $0.id == current }) else {
            return
        }
        let nextIndex = forward
            ? (idx + 1) % entries.count
            : (idx - 1 + entries.count) % entries.count
        let targetID = entries[nextIndex].id
        if selection != targetID {
            AppHaptics.impact(.light)
            selection = targetID
        }
    }

    private func reconcileSplitState() {
        let validIDs = Set(windowLiveSessions.map(\.id)).union(pendingConnections.map(\.id))
        splitState.reconcile(primaryID: selection, validIDs: validIDs)
    }

    private func syncModalPresentationState() {
        let primaryID = selectedLive?.id
        let secondaryID = secondaryLive?.id
        let isModal = isModalOverSelectedTerminal
        for live in windowLiveSessions {
            if live.id == primaryID || live.id == secondaryID {
                live.hasModalSheetPresented = isModal
            } else if live.hasModalSheetPresented {
                live.hasModalSheetPresented = false
            }
        }
    }

    @ViewBuilder
    private var keyboardShortcutsLayer: some View {
        let modalFree = activeToolSheet == nil && !switching && closingTab == nil && inspectingSecurity == nil && splitPickerRequest == nil && !appLock.isLocked
        ZStack {
            if isTerminalActive && modalFree {
                SessionShortcutButton("Hosts Quick Connect", key: "t", modifiers: .command) {
                    newTab()
                }
                SessionShortcutButton("Close Tab", key: "w", modifiers: .command) {
                    closeCurrent()
                }

                ForEach(1...9, id: \.self) { number in
                    if tabEntries.indices.contains(number - 1) {
                        SessionShortcutButton(
                            "Switch to Tab \(number)",
                            key: KeyEquivalent(Character(String(number))),
                            modifiers: .command
                        ) {
                            switchTab(number - 1)
                        }
                    }
                }

                if horizontalSizeClass == .regular && (isSplitVisible || tabEntries.count > 1) {
                    SessionShortcutButton(isSplitVisible ? "Next Pane" : "Next Tab", key: "]", modifiers: .command) {
                        handleBracketShortcut(forward: true)
                    }
                    SessionShortcutButton(isSplitVisible ? "Previous Pane" : "Previous Tab", key: "[", modifiers: .command) {
                        handleBracketShortcut(forward: false)
                    }
                }

                if horizontalSizeClass == .regular && selectedLive != nil {
                    SessionShortcutButton("Split Right", key: "d", modifiers: .command) {
                        triggerSplit(axis: .horizontal, allowCycleWhenSplit: true)
                    }
                    SessionShortcutButton("Split Down", key: "e", modifiers: [.command, .shift]) {
                        triggerSplit(axis: .vertical, allowCycleWhenSplit: true)
                    }
                }

                if focusedLive != nil {
                    SessionShortcutButton("Increase Font Size", key: "=", modifiers: .command) {
                        adjustFontSize(by: 1)
                    }
                    SessionShortcutButton("", key: "+", modifiers: .command) {
                        adjustFontSize(by: 1)
                    }
                    SessionShortcutButton("", key: "+", modifiers: [.command, .shift]) {
                        adjustFontSize(by: 1)
                    }
                    SessionShortcutButton("Decrease Font Size", key: "-", modifiers: .command) {
                        adjustFontSize(by: -1)
                    }
                    SessionShortcutButton("Reset Font Size", key: "0", modifiers: .command) {
                        resetFontSize()
                    }
                    SessionShortcutButton("Git Diff Inspector", key: "d", modifiers: [.command, .shift]) {
                        openGitDiffShortcut()
                    }
                    SessionShortcutButton("Dev Server Preview", key: "p", modifiers: [.command, .shift]) {
                        openDevServerPreviewShortcut()
                    }
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ConnectionSecuritySheet: View {
    let title: String
    let algorithms: NegotiatedAlgorithms
    @Environment(\.dismiss) private var dismiss

    private var isAEAD: Bool {
        let lower = algorithms.cipher.lowercased()
        return lower.contains("gcm") || lower.contains("poly1305")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: algorithms.isPostQuantum ? "lock.shield.fill" : "lock.fill")
                            .font(.title2)
                            .foregroundStyle(algorithms.isPostQuantum ? Color.green : Color.orange)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(algorithms.isPostQuantum ? "Post-Quantum Hybrid" : "Classical Key Exchange")
                                .font(.headline)
                            Text(algorithms.isPostQuantum
                                 ? "Protected with post-quantum hybrid key exchange."
                                 : "The server did not negotiate a post-quantum key exchange.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    algorithmRow("Key Exchange", value: algorithms.kex)
                    algorithmRow("Host Key", value: algorithms.hostKey)
                    algorithmRow("Cipher", value: algorithms.cipher)
                    algorithmRow("MAC", value: algorithms.mac.isEmpty ? "AEAD integrated" : algorithms.mac)
                } header: {
                    Text("Negotiated Algorithms")
                } footer: {
                    if isAEAD {
                        Text("AEAD ciphers authenticate integrity inline; the MAC slot is reported by libssh2 for compatibility.")
                    }
                }
            }
            .navigationTitle(title.isEmpty ? "Connection Security" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 340)
        .presentationDetents([.medium])
    }

    private func algorithmRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// Observes T6's tab notifications with this window's scene as the object.
private struct TabNotifications: View {
    let scene: UIWindowScene
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    let onSwitchTab: (Int) -> Void
    private let center = NotificationCenter.default

    var body: some View {
        Color.clear
            .onReceive(center.publisher(for: .termNewTab, object: scene)) { _ in onNewTab() }
            .onReceive(center.publisher(for: .termCloseTab, object: scene)) { _ in onCloseTab() }
            .onReceive(center.publisher(for: .termSwitchTab, object: scene)) { note in
                if let i = note.userInfo?[HardwareKeyCommands.tabIndexKey] as? Int { onSwitchTab(i) }
            }
            .allowsHitTesting(false)
    }
}

/// Finds the window scene this view lives in.
struct SceneReader: UIViewRepresentable {
    @Binding var scene: UIWindowScene?

    final class Probe: UIView {
        var onScene: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onScene?(window?.windowScene) }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe(); v.isUserInteractionEnabled = false
        v.onScene = { s in DispatchQueue.main.async { scene = s } }
        return v
    }
    func updateUIView(_ uiView: Probe, context: Context) {}
}

enum SessionFontShortcuts {
    static func adjustedFontSize(from current: Double, delta: Double) -> Double {
        min(max(current + delta, AppearanceSettings.minFontSize), AppearanceSettings.maxFontSize)
    }
}

struct SessionShortcutButton: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(_ title: String, key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

enum SessionToolSheet: Identifiable {
    case snippets(LiveSession)
    case sftp(LiveSession, SSHConnection)
    case portForwards(LiveSession, SSHConnection)
    case gitDiff(LiveSession)
    case devServerPreview(LiveSession)
    case security(LiveSession, NegotiatedAlgorithms)
    case paywall

    var id: String {
        switch self {
        case .snippets(let live): "snippets-\(live.id)"
        case .sftp(let live, _): "sftp-\(live.id)"
        case .portForwards(let live, _): "forwards-\(live.id)"
        case .gitDiff(let live): "gitdiff-\(live.id)"
        case .devServerPreview(let live): "preview-\(live.id)"
        case .security(let live, _): "security-\(live.id)"
        case .paywall: "paywall"
        }
    }

    @MainActor
    static func gitDiff(for live: LiveSession, isProUnlocked: Bool) -> SessionToolSheet? {
        guard live.connectionStatus == .connected else { return nil }
        return isProUnlocked ? .gitDiff(live) : .paywall
    }

    @MainActor
    static func devServerPreview(for live: LiveSession, isProUnlocked: Bool) -> SessionToolSheet? {
        guard live.connectionStatus == .connected else { return nil }
        if !isProUnlocked {
            return .paywall
        }
        guard live.session is SSHConnection else { return nil }
        return .devServerPreview(live)
    }
}

/// Shared 44×44 tools menu for Snippets, SFTP Files, Port Forwards, Git Diff, Dev Server Preview, and Security.
struct SessionToolsMenu: View {
    let live: LiveSession
    let isProUnlocked: Bool
    let foregroundColor: Color
    let onSelect: (SessionToolSheet) -> Void

    private var sshConnection: SSHConnection? {
        live.session as? SSHConnection
    }

    var body: some View {
        Menu {
            Button("Command Snippets", systemImage: "bolt.fill") {
                AppHaptics.impact(.light)
                onSelect(.snippets(live))
            }

            Button("SFTP Files", systemImage: "folder.fill") {
                AppHaptics.impact(.light)
                guard isProUnlocked else {
                    onSelect(.paywall)
                    return
                }
                if let sshConnection {
                    onSelect(.sftp(live, sshConnection))
                }
            }
            .disabled(isProUnlocked && sshConnection == nil)

            Button("Port Forwards", systemImage: "arrow.left.arrow.right") {
                AppHaptics.impact(.light)
                guard isProUnlocked else {
                    onSelect(.paywall)
                    return
                }
                if let sshConnection {
                    onSelect(.portForwards(live, sshConnection))
                }
            }
            .disabled(isProUnlocked && sshConnection == nil)

            Divider()

            Button("Git Diff", systemImage: "doc.text.magnifyingglass") {
                AppHaptics.impact(.light)
                guard isProUnlocked else {
                    onSelect(.paywall)
                    return
                }
                onSelect(.gitDiff(live))
            }
            .disabled(isProUnlocked && live.connectionStatus != .connected)

            Button("Dev Server Preview", systemImage: "safari") {
                AppHaptics.impact(.light)
                guard isProUnlocked else {
                    onSelect(.paywall)
                    return
                }
                if sshConnection != nil {
                    onSelect(.devServerPreview(live))
                }
            }
            .disabled(isProUnlocked && (sshConnection == nil || live.connectionStatus != .connected))

            Divider()

            Button {
                AppHaptics.impact(.light)
                guard isProUnlocked else {
                    onSelect(.paywall)
                    return
                }
                live.showAIAgentControls.toggle()
            } label: {
                Label(
                    live.showAIAgentControls ? "Hide AI Agent Controls" : "AI Agent Controls",
                    systemImage: live.showAIAgentControls ? "sparkles.rectangle.stack.fill" : "sparkles"
                )
            }

            if let algorithms = live.algorithms {
                Divider()

                Button {
                    AppHaptics.impact(.light)
                    onSelect(.security(live, algorithms))
                } label: {
                    Label(
                        algorithms.isPostQuantum ? "Security: Post-Quantum" : "Security: Classical",
                        systemImage: algorithms.isPostQuantum ? "lock.shield.fill" : "lock.fill"
                    )
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .minTapTarget()
        }
        .accessibilityLabel("Session Tools")
    }
}

private struct SessionToolSheetsModifier: ViewModifier {
    @Binding var item: SessionToolSheet?
    let theme: TerminalTheme

    func body(content: Content) -> some View {
        content
            .sheet(item: $item) { sheet in
                Group {
                    switch sheet {
                    case .snippets(let live):
                        SnippetDrawerView { snippet in
                            live.controller.send(snippet.payloadBytes)
                        }
                    case .sftp(let live, let conn):
                        SFTPBrowserView(connection: conn, hostTitle: live.title)
                    case .portForwards(let live, let conn):
                        PortForwardsView(connection: conn, hostID: live.hostID, hostTitle: live.title)
                    case .gitDiff(let live):
                        GitDiffInspectorSheet(live: live)
                    case .devServerPreview(let live):
                        DevServerPreviewSheet(live: live)
                    case .security(let live, let algorithms):
                        ConnectionSecuritySheet(title: live.title, algorithms: algorithms)
                    case .paywall:
                        ProPaywallView()
                    }
                }
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
            }
    }
}

extension View {
    func sessionToolSheets(item: Binding<SessionToolSheet?>, theme: TerminalTheme) -> some View {
        modifier(SessionToolSheetsModifier(item: item, theme: theme))
    }
}
