import SwiftUI
import SwiftData
import SSHKit
import Store
import TermUI

/// Dashboard listing open AI terminal tabs and live/detached remote `tmux` sessions across saved hosts.
struct AgentsDashboardView: View {
    private struct DiscoveredSession: Identifiable, Hashable {
        let hostID: UUID
        let hostLabel: String
        let session: TMuxSessionHelper.RemoteAISession

        var id: String { "\(hostID.uuidString)::\(session.sessionName)" }
    }

    enum HostScanStatus: Sendable, Equatable {
        case ok(sessionCount: Int)
        case tmuxMissing
        case needsAuthOrTrust(reason: String)
        case unreachable(reason: String)

        var issueReason: String? {
            switch self {
            case .ok:
                nil
            case .tmuxMissing:
                "tmux not installed"
            case .needsAuthOrTrust(let reason), .unreachable(let reason):
                reason
            }
        }

        var symbolName: String {
            switch self {
            case .ok:
                "checkmark.circle"
            case .tmuxMissing:
                "terminal"
            case .needsAuthOrTrust:
                "lock.shield"
            case .unreachable:
                "wifi.slash"
            }
        }
    }

    private struct HostScanOutcome: Sendable, Identifiable {
        let hostID: UUID
        let hostLabel: String
        let sessions: [TMuxSessionHelper.RemoteAISession]
        let status: HostScanStatus

        var id: UUID { hostID }
    }

    @Environment(SessionManager.self) private var sessionManager
    @Environment(ProStore.self) private var proStore
    @Environment(\.openSessionTab) private var openSessionTab
    @Environment(\.connectHost) private var connectHost
    @Environment(\.launchAIAgent) private var launchAIAgent
    @Environment(\.runTerminalCommand) private var runTerminalCommand
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var hosts: [Host]

    @State private var remoteSessions: [DiscoveredSession] = []
    @State private var scanOutcomes: [HostScanOutcome] = []
    @State private var isScanning = false
    @State private var hasScannedOnce = false
    @State private var scanGeneration = 0
    @State private var killingSession: DiscoveredSession?
    @State private var killError: String?
    @State private var showingLaunchSheet = false
    @State private var showingPaywall = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var openAISessions: [LiveSession] {
        sessionManager.sessions.filter { $0.aiAgentContext != nil }
    }

    private var aiSessions: [DiscoveredSession] {
        remoteSessions.filter(\.session.isAISession)
    }

    private var otherTmuxSessions: [DiscoveredSession] {
        remoteSessions.filter { !$0.session.isAISession }
    }

    private var hostScanIssues: [HostScanOutcome] {
        scanOutcomes
            .filter { $0.status.issueReason != nil }
            .sorted { lhs, rhs in
                let cmp = lhs.hostLabel.localizedCaseInsensitiveCompare(rhs.hostLabel)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
    }

    var body: some View {
        Group {
            if proStore.isProUnlocked {
                dashboardList
            } else {
                proPromptView
            }
        }
        .toolbar {
            if proStore.isProUnlocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.impact(.light)
                        showingLaunchSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Launch AI Agent")
                    .disabled(hosts.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingLaunchSheet) {
            LaunchAIAgentSheet(initialHost: nil)
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
        }
        .confirmationDialog(
            "Kill remote tmux session?",
            isPresented: Binding(get: { killingSession != nil }, set: { if !$0 { killingSession = nil } }),
            titleVisibility: .visible,
            presenting: killingSession
        ) { item in
            Button("Kill Session", role: .destructive) {
                Task { await killSession(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let detail = item.session.isAISession
                ? "Unsaved agent state in that tmux session will stop."
                : "Running processes in that tmux session will stop."
            Text("This terminates \"\(item.session.sessionName)\" on \(item.hostLabel). \(detail)")
        }
        .alert(
            "Action Failed",
            isPresented: Binding(get: { killError != nil }, set: { if !$0 { killError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(killError ?? "")
        }
        .task(id: hosts.map(\.id)) {
            guard proStore.isProUnlocked else { return }
            await scanAllHosts()
        }
    }

    private var dashboardList: some View {
        List {
            if !openAISessions.isEmpty {
                Section("Open AI Tabs") {
                    ForEach(openAISessions) { live in
                        openTabRow(live)
                    }
                }
            }

            if !aiSessions.isEmpty || (isScanning && otherTmuxSessions.isEmpty && hostScanIssues.isEmpty) {
                Section {
                    ForEach(aiSessions) { item in
                        remoteSessionRow(item)
                    }
                } header: {
                    sectionHeader("Remote AI Sessions", showSpinner: isScanning)
                } footer: {
                    if !aiSessions.isEmpty && otherTmuxSessions.isEmpty && hostScanIssues.isEmpty {
                        Text("Pull down to refresh active and detached tmux sessions.")
                    }
                }
            }

            if !otherTmuxSessions.isEmpty {
                Section {
                    ForEach(otherTmuxSessions) { item in
                        otherTmuxSessionRow(item)
                    }
                } header: {
                    sectionHeader("Other tmux Sessions", showSpinner: isScanning && aiSessions.isEmpty)
                } footer: {
                    if hostScanIssues.isEmpty {
                        Text("Tap to attach in a terminal tab, or swipe to kill a session.")
                    }
                }
            }

            if !hostScanIssues.isEmpty {
                Section {
                    ForEach(hostScanIssues) { outcome in
                        hostScanStatusRow(outcome)
                    }
                } header: {
                    sectionHeader(
                        "Host Scan Status",
                        showSpinner: isScanning && aiSessions.isEmpty && otherTmuxSessions.isEmpty
                    )
                } footer: {
                    Text("Connect once to trust host keys or sign in, then pull down to refresh.")
                }
            }
        }
        .refreshable {
            await scanAllHosts()
        }
        .overlay {
            if openAISessions.isEmpty && remoteSessions.isEmpty && hostScanIssues.isEmpty && !isScanning {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "No Saved Hosts",
                        systemImage: "server.rack",
                        description: Text("Add an SSH host in the Hosts segment to launch and discover remote AI agents.")
                    )
                } else if hasScannedOnce {
                    ContentUnavailableView {
                        Label("No Active AI Sessions", systemImage: "sparkles")
                    } description: {
                        Text("Launch Claude Code, Antigravity, Codex, Aider, OpenCode, or a custom CLI in a persistent tmux session.")
                    } actions: {
                        Button {
                            AppHaptics.impact(.light)
                            showingLaunchSheet = true
                        } label: {
                            Label("Launch AI Agent", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AgentVisuals.appleProAmber)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, showSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            if showSpinner {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private func openTabRow(_ live: LiveSession) -> some View {
        let context = live.aiAgentContext
        let tint = context.map { AgentVisuals.agentTint(for: $0.agent) } ?? AgentVisuals.appleProAmber
        let symbol = context.map { AgentVisuals.agentSymbol(for: $0.agent) } ?? "sparkles"

        return Button {
            AppHaptics.impact(.light)
            openSessionTab(live.id)
        } label: {
            HStack(spacing: 12) {
                SquircleIcon(
                    symbolName: symbol,
                    tint: tint,
                    fillOpacity: theme.isDark ? 0.22 : 0.14,
                    rimOpacity: 0.38
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ConnectionStatusDot(
                            status: live.connectionStatus,
                            size: 7,
                            glow: live.connectionStatus == .connected
                        )
                        Text(live.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if let context {
                        Text("\(context.workingDirectory) · \(context.sessionName)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text("Resume")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(theme.isDark ? 0.18 : 0.12), in: Capsule())
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(live.title)")
    }

    private func remoteSessionRow(_ item: DiscoveredSession) -> some View {
        let session = item.session
        let descriptor = AgentVisuals.agentDescriptor(forSlug: session.agentSlug)
        let tint = AgentVisuals.agentTint(for: descriptor)
        let badge = session.projectSlug.isEmpty ? session.sessionName : session.projectSlug
        let subtitle: String = {
            if !session.isTermAppManaged && session.sessionName != badge {
                let prefix = "\(item.hostLabel) · \(session.sessionName)"
                guard let path = session.currentPath, !path.isEmpty else { return prefix }
                return "\(prefix) · \(path)"
            }
            return subtitleLine(hostLabel: item.hostLabel, path: session.currentPath)
        }()

        return tmuxSessionRow(
            item: item,
            iconSymbol: AgentVisuals.agentSymbol(for: descriptor),
            iconTint: tint,
            title: descriptor.name,
            badgeText: badge,
            badgeTint: tint,
            subtitle: subtitle,
            accessibilityDescription: "\(descriptor.name) on \(item.hostLabel), \(session.isAttached ? "attached" : "idle")",
            onAttach: { forceNewTab in attach(item, forceNewTab: forceNewTab) }
        )
    }

    private func otherTmuxSessionRow(_ item: DiscoveredSession) -> some View {
        let session = item.session
        let commandBadge = session.detectedCommand ?? ""
        return tmuxSessionRow(
            item: item,
            iconSymbol: "terminal",
            iconTint: AgentVisuals.slateColor,
            title: session.sessionName,
            badgeText: commandBadge,
            badgeTint: AgentVisuals.slateColor,
            subtitle: subtitleLine(hostLabel: item.hostLabel, path: session.currentPath),
            accessibilityDescription: "tmux session \(session.sessionName) on \(item.hostLabel), \(session.isAttached ? "attached" : "idle")",
            onAttach: { _ in attachGeneralSession(item) }
        )
    }

    private func tmuxSessionRow(
        item: DiscoveredSession,
        iconSymbol: String,
        iconTint: Color,
        title: String,
        badgeText: String,
        badgeTint: Color,
        subtitle: String,
        accessibilityDescription: String,
        onAttach: @escaping (Bool) -> Void
    ) -> some View {
        let session = item.session
        let ledColor = session.isAttached ? AgentVisuals.activeGreen : AgentVisuals.appleProAmber
        let activityDate = session.lastActivityAt ?? session.createdAt

        return Button {
            AppHaptics.impact(.light)
            onAttach(false)
        } label: {
            HStack(spacing: 12) {
                SquircleIcon(
                    symbolName: iconSymbol,
                    tint: iconTint,
                    fillOpacity: theme.isDark ? 0.20 : 0.14,
                    rimOpacity: 0.36
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        CloudStatusLED(color: ledColor, size: 7)

                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !badgeText.isEmpty {
                            Text(badgeText)
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(badgeTint)
                                .background(badgeTint.opacity(theme.isDark ? 0.16 : 0.12), in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.isAttached ? "Attached" : "Idle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ledColor)

                    if activityDate != nil {
                        Text(AgentVisuals.relativeActivityString(from: activityDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityDescription)
        .contextMenu {
            Button("Attach", systemImage: "terminal") {
                AppHaptics.impact(.light)
                onAttach(true)
            }
            Button("Kill Session", systemImage: "xmark.octagon", role: .destructive) {
                killingSession = item
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                killingSession = item
            } label: {
                Label("Kill", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                AppHaptics.impact(.light)
                onAttach(false)
            } label: {
                Label("Attach", systemImage: "terminal")
            }
            .tint(AgentVisuals.activeGreen)
        }
    }

    private func hostScanStatusRow(_ outcome: HostScanOutcome) -> some View {
        let reason = outcome.status.issueReason ?? ""
        let tint: Color = switch outcome.status {
        case .ok:
            AgentVisuals.activeGreen
        case .tmuxMissing:
            AgentVisuals.slateColor
        case .needsAuthOrTrust:
            AgentVisuals.appleProAmber
        case .unreachable:
            Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
        }

        return HStack(spacing: 12) {
            SquircleIcon(
                symbolName: outcome.status.symbolName,
                tint: tint,
                fillOpacity: theme.isDark ? 0.18 : 0.12,
                rimOpacity: 0.34,
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.hostLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let host = hosts.first(where: { $0.id == outcome.hostID }) {
                Button("Connect") {
                    AppHaptics.impact(.light)
                    connectHost?(host)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
                .accessibilityLabel("Connect to \(outcome.hostLabel)")
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitleLine(hostLabel: String, path: String?) -> String {
        guard let path, !path.isEmpty else { return hostLabel }
        return "\(hostLabel) · \(path)"
    }

    private func attach(_ item: DiscoveredSession, forceNewTab: Bool = false) {
        if !forceNewTab,
           let existing = sessionManager.sessions.first(where: {
               $0.hostID == item.hostID
                   && $0.aiAgentContext?.sessionName == item.session.sessionName
                   && $0.connectionStatus == .connected
           }) {
            openSessionTab(existing.id)
            return
        }

        guard let host = hosts.first(where: { $0.id == item.hostID }) else { return }
        let descriptor = AgentVisuals.agentDescriptor(forSlug: item.session.agentSlug)
        let context = AIAgentLaunchContext(
            agent: descriptor,
            sessionName: item.session.sessionName,
            workingDirectory: item.session.currentPath ?? "~",
            hostID: host.id
        )
        let command = TMuxSessionHelper.attachCommand(sessionName: item.session.sessionName)
        launchAIAgent?(host, context, command)
    }

    private func attachGeneralSession(_ item: DiscoveredSession) {
        guard let host = hosts.first(where: { $0.id == item.hostID }) else { return }
        let command = TMuxSessionHelper.attachCommand(sessionName: item.session.sessionName)
        runTerminalCommand?(host, command)
    }

    private func killSession(_ item: DiscoveredSession) async {
        guard let host = hosts.first(where: { $0.id == item.hostID }) else { return }
        let target = AgentHostTarget(host: host, sessionManager: sessionManager)
        do {
            _ = try await AgentAuthHelper.exec(
                TMuxSessionHelper.killSessionCommand(sessionName: item.session.sessionName),
                on: target
            )
            AppHaptics.notify(.success)
            remoteSessions.removeAll { $0.id == item.id }
        } catch {
            AppHaptics.notify(.error)
            killError = error.localizedDescription
        }
    }

    private func scanAllHosts() async {
        scanGeneration += 1
        let generation = scanGeneration
        let targets = hosts.map { AgentHostTarget(host: $0, sessionManager: sessionManager) }
        let knownCommands = Self.buildKnownCommands()

        guard !targets.isEmpty else {
            remoteSessions = []
            scanOutcomes = []
            isScanning = false
            hasScannedOnce = true
            return
        }

        isScanning = true

        let outcomes = await withTaskGroup(of: HostScanOutcome.self) { group in
            for target in targets {
                group.addTask {
                    await Self.scanHost(target, knownCommands: knownCommands)
                }
            }

            var collected: [HostScanOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        guard !Task.isCancelled, generation == scanGeneration else { return }

        let discovered = outcomes.flatMap { outcome in
            outcome.sessions.map {
                DiscoveredSession(hostID: outcome.hostID, hostLabel: outcome.hostLabel, session: $0)
            }
        }
        remoteSessions = discovered.sorted { lhs, rhs in
            if lhs.session.isAttached != rhs.session.isAttached {
                return lhs.session.isAttached && !rhs.session.isAttached
            }
            let lhsDate = lhs.session.lastActivityAt ?? lhs.session.createdAt ?? .distantPast
            let rhsDate = rhs.session.lastActivityAt ?? rhs.session.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            let hostOrder = lhs.hostLabel.localizedCaseInsensitiveCompare(rhs.hostLabel)
            if hostOrder != .orderedSame {
                return hostOrder == .orderedAscending
            }
            return lhs.session.sessionName.localizedCaseInsensitiveCompare(rhs.session.sessionName) == .orderedAscending
        }
        scanOutcomes = outcomes
        isScanning = false
        hasScannedOnce = true
    }

    private static func buildKnownCommands() -> [String: String] {
        var commands: [String: String] = [:]
        for preset in HostProjectStore.allPresets() {
            let cmd = preset.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                commands[cmd] = preset.slug
            }
        }
        return commands
    }

    private nonisolated static func scanHost(
        _ target: AgentHostTarget,
        knownCommands: [String: String]
    ) async -> HostScanOutcome {
        do {
            let result = try await AgentAuthHelper.exec(
                TMuxSessionHelper.listSessionsCommand(),
                on: target,
                timeout: .seconds(8)
            )
            if TMuxSessionHelper.isTmuxMissing(in: result.stdout) {
                return HostScanOutcome(
                    hostID: target.id,
                    hostLabel: target.displayName,
                    sessions: [],
                    status: .tmuxMissing
                )
            }
            let parsed = TMuxSessionHelper.parseSessions(
                from: result.stdout,
                onlyTermAppManaged: false,
                knownCommands: knownCommands
            )
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: parsed,
                status: .ok(sessionCount: parsed.count)
            )
        } catch let error as AgentRemoteError where error.isAuthOrTrustIssue {
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: [],
                status: .needsAuthOrTrust(reason: conciseAuthReason(for: error, target: target))
            )
        } catch let error as SSHError {
            switch error {
            case .authenticationFailed:
                return HostScanOutcome(
                    hostID: target.id,
                    hostLabel: target.displayName,
                    sessions: [],
                    status: .needsAuthOrTrust(reason: "Needs login or authentication")
                )
            case .hostKeyRejected:
                return HostScanOutcome(
                    hostID: target.id,
                    hostLabel: target.displayName,
                    sessions: [],
                    status: .needsAuthOrTrust(reason: "Needs login or host key trust")
                )
            default:
                return HostScanOutcome(
                    hostID: target.id,
                    hostLabel: target.displayName,
                    sessions: [],
                    status: .unreachable(reason: conciseUnreachableReason(for: error, hostLabel: target.displayName))
                )
            }
        } catch {
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: [],
                status: .unreachable(reason: conciseUnreachableReason(for: error, hostLabel: target.displayName))
            )
        }
    }

    private nonisolated static func conciseAuthReason(
        for error: AgentRemoteError,
        target: AgentHostTarget
    ) -> String {
        switch error {
        case .untrustedHostKey:
            "Needs login or host key trust"
        case .hostKeyMismatch:
            "Host key changed — connect to verify"
        case .missingCredentials:
            "Missing SSH key credentials"
        case .needsInteractiveAuth:
            if target.authMethod == "keyboardInteractive" {
                "Needs interactive 2FA login"
            } else {
                "Needs login or host key trust"
            }
        case .commandFailed(let message):
            message
        }
    }

    private nonisolated static func conciseUnreachableReason(
        for error: Error,
        hostLabel: String
    ) -> String {
        let raw = error.localizedDescription
            .replacingOccurrences(of: "\(hostLabel): ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Offline / timed out"
        }
        if lower.contains("could not reach") || lower.contains("connection") {
            return "Offline / unreachable"
        }
        return raw.isEmpty ? "Offline / unreachable" : raw
    }

    private var proPromptView: some View {
        let cardFill = theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        let cardStroke = theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)

        return ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    SquircleIcon(
                        symbolName: "sparkles",
                        tint: AgentVisuals.appleProAmber,
                        fillOpacity: theme.isDark ? 0.22 : 0.14,
                        rimOpacity: 0.44,
                        size: 60
                    )

                    Text("AI Agent Sessions")
                        .font(.title3.bold())

                    Text("Launch, monitor, and reattach Claude Code, Antigravity, Codex, Aider & OpenCode in persistent tmux sessions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 14) {
                    proFeatureRow(
                        icon: "terminal.fill",
                        tint: AgentVisuals.appleProAmber,
                        title: "Persistent tmux Sessions",
                        detail: "Start or reattach remote coding agents across background drops without losing context."
                    )

                    Divider()

                    proFeatureRow(
                        icon: "folder.badge.gearshape",
                        tint: Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0),
                        title: "Remote Folder Picker & Presets",
                        detail: "Browse server directories, star project favorites, and save custom agent CLIs."
                    )

                    Divider()

                    proFeatureRow(
                        icon: "text.bubble.fill",
                        tint: AgentVisuals.activeGreen,
                        title: "Quick Actions & Prompt Composer",
                        detail: "1-tap Approve, Deny, Esc, Shift+Tab, /compact, and multi-line voice-ready prompt pasting."
                    )
                }
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )

                Button {
                    AppHaptics.impact(.light)
                    showingPaywall = true
                } label: {
                    Label("Unlock TermApp Pro", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AgentVisuals.appleProAmber)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func proFeatureRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SquircleIcon(
                symbolName: icon,
                tint: tint,
                fillOpacity: theme.isDark ? 0.20 : 0.14,
                rimOpacity: 0.36,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
