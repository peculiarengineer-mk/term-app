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

/// Floating frosted-glass pill docked above the tab bar when viewing Hosts/Keys/Settings with open sessions.
struct ActiveSessionPill: View {
    let title: String
    let status: LiveSession.ConnectionStatus
    let totalCount: Int
    let showSwitcher: Bool
    let isDark: Bool
    let onResume: () -> Void
    let onSwitch: () -> Void

    private var strokeGradient: LinearGradient {
        LinearGradient(
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
                    ConnectionStatusDot(status: status, size: 8, glow: true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Active Session")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

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
                    }

                    Spacer(minLength: 4)

                    if !showSwitcher {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .padding(.trailing, showSwitcher ? 4 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active session: \(title)")
            .accessibilityValue(status.accessibilityLabel)

            if showSwitcher {
                Button(action: onSwitch) {
                    Image(systemName: "square.on.square")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(
                            Color.primary.opacity(isDark ? 0.08 : 0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .accessibilityLabel("Switch sessions (\(totalCount) open)")
            }
        }
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(strokeGradient, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(isDark ? 0.42 : 0.14), radius: 14, x: 0, y: 6)
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

    @ViewBuilder let hostList: (ActiveSessionPill?) -> HostList
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var manager
    @Environment(ProStore.self) private var proStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
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

    private struct SecurityInspection: Identifiable {
        let id: UUID
        let title: String
        let algorithms: NegotiatedAlgorithms
    }

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

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

    private var activeSessionPill: ActiveSessionPill? {
        guard selection == nil, !manager.sessions.isEmpty || !pendingConnections.isEmpty else {
            return nil
        }

        let matchedByLastID: TabEntry? = lastSelectedID.flatMap { id in
            if let live = manager.session(id: id) { return .live(live) }
            if let pending = pendingConnections.first(where: { $0.id == id }) { return .pending(pending) }
            return nil
        }
        let target: TabEntry? = matchedByLastID
            ?? manager.sessions.last.map(TabEntry.live)
            ?? pendingConnections.last.map(TabEntry.pending)

        let totalCount = manager.sessions.count + pendingConnections.count
        let showSwitcher = totalCount > 1 && !manager.sessions.isEmpty

        switch target {
        case .live(let live):
            return ActiveSessionPill(
                title: live.title,
                status: live.connectionStatus,
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

    var body: some View {
        VStack(spacing: 0) {
            if selectedLive != nil || selectedPending != nil {
                tabBar
            }
            if let live = selectedLive {
                TerminalPane(live: live)
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
            if let scene {
                TabNotifications(
                    scene: scene,
                    onNewTab: { newTab() },
                    onCloseTab: { closeCurrent() },
                    onSwitchTab: { switchTab($0) }
                )
            }
        }
        .onChange(of: selection) { _, newSelection in
            if let newSelection {
                lastSelectedID = newSelection
            }
        }
        .onChange(of: windowLiveSessions.map(\.id)) { _, liveIDs in
            let liveSet = Set(liveIDs)
            let pendingSet = Set(pendingConnections.map(\.id))
            tabOrder.removeAll { !liveSet.contains($0) && !pendingSet.contains($0) }
            if let s = selection, !tabOrder.contains(s) {
                selection = tabOrder.last
            }
        }
        .sheet(isPresented: $switching) {
            SessionSwitcher(
                selectedID: selection,
                onSelect: { addTab($0) },
                onOpenInWindow: { moveToWindow($0) }
            )
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

                HStack(spacing: 4) {
                    if let selectedLive {
                        SessionToolsMenu(
                            live: selectedLive,
                            isProUnlocked: proStore.isProUnlocked,
                            foregroundColor: theme.foregroundColor
                        ) { tool in
                            activeToolSheet = tool
                        }
                    }

                    if let selectedLive, let algorithms = selectedLive.algorithms {
                        Button {
                            AppHaptics.impact(.light)
                            inspectingSecurity = SecurityInspection(
                                id: selectedLive.id,
                                title: selectedLive.title,
                                algorithms: algorithms
                            )
                        } label: {
                            Image(systemName: algorithms.isPostQuantum ? "lock.shield.fill" : "lock.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(algorithms.isPostQuantum ? Color.green : Color.orange)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
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
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.foregroundColor)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("New Tab")
                    }

                    Button {
                        AppHaptics.impact(.light)
                        switching = true
                    } label: {
                        Image(systemName: "square.on.square")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.foregroundColor)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sessions")
                }
                .padding(.trailing, 8)
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
        return HStack(spacing: 4) {
            Button {
                AppHaptics.impact(.light)
                selection = live.id
            } label: {
                HStack(spacing: 6) {
                    ConnectionStatusDot(status: live.connectionStatus)
                    if let ai = live.aiAgentContext {
                        Image(systemName: AgentVisuals.agentSymbol(for: ai.agent))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AgentVisuals.agentTint(for: ai.agent))
                            .accessibilityHidden(true)
                    }
                    Text(live.title)
                        .lineLimit(1)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
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
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(live.title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected ? 4 : 12)
        .padding(.vertical, isSelected ? 2 : 0)
        .foregroundStyle(isSelected ? theme.foregroundColor : theme.secondaryForegroundColor)
        .background(
            isSelected
                ? theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16)
                : theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? theme.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            if live.ephemeralHost != nil {
                Button("Save Host", systemImage: "bookmark.badge.plus") {
                    manager.saveEphemeralHost(for: live.id, in: modelContext)
                }
            }
            Button("Move to New Window", systemImage: "macwindow.badge.plus") { moveToWindow(live.id) }
            Button("Close", systemImage: "xmark", role: .destructive) {
                requestCloseLive(live)
            }
        }
    }

    private func pendingTabChip(for pending: PendingConnection) -> some View {
        let isSelected = selection == pending.id
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
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(chipTitle)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected ? 4 : 12)
        .padding(.vertical, isSelected ? 2 : 0)
        .foregroundStyle(isSelected ? theme.foregroundColor : theme.secondaryForegroundColor)
        .background(
            isSelected
                ? theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16)
                : theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? theme.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
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
        pendingLaunchCommand: String? = nil
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
        selection = pendingID

        model.onConnected = { conn, bridge in
            guard pendingConnections.contains(where: { $0.id == pendingID }) else {
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
        if lastSelectedID == pendingID {
            lastSelectedID = nil
        }
    }

    private func requestCloseLive(_ live: LiveSession) {
        if live.connectionStatus == .connected {
            closingTab = live
        } else {
            AppHaptics.impact(.light)
            manager.close(live.id)
        }
    }

    func addTab(_ id: UUID) {
        guard manager.session(id: id) != nil else { return }
        manager.show(id, in: windowID) // moves it out of any other window
        if !tabOrder.contains(id) { tabOrder.append(id) }
        selection = id
    }

    private func moveToWindow(_ id: UUID) {
        manager.detach(id)
        tabOrder.removeAll { $0 == id }
        if selection == id { selection = tabOrder.last }
        if lastSelectedID == id { lastSelectedID = nil }
        openWindow(value: id)
    }

    fileprivate func newTab() { selection = nil }

    fileprivate func closeCurrent() {
        guard let s = selection else { return }
        if let live = windowLiveSessions.first(where: { $0.id == s }) {
            requestCloseLive(live)
        } else if pendingConnections.contains(where: { $0.id == s }) {
            cancelPending(s)
        }
    }

    fileprivate func switchTab(_ index: Int) {
        if tabOrder.indices.contains(index) { selection = tabOrder[index] }
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

enum SessionToolSheet: Identifiable {
    case snippets(LiveSession)
    case sftp(LiveSession, SSHConnection)
    case portForwards(LiveSession, SSHConnection)
    case paywall

    var id: String {
        switch self {
        case .snippets(let live): "snippets-\(live.id)"
        case .sftp(let live, _): "sftp-\(live.id)"
        case .portForwards(let live, _): "forwards-\(live.id)"
        case .paywall: "paywall"
        }
    }
}

/// Shared 40x40 tools menu for Snippets, SFTP Files, and Port Forwards across tab and window bars.
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
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
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
