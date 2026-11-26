import SwiftUI
import SwiftData
import SSHKit
import Store
import TermUI

/// Dashboard listing open AI terminal tabs and live/detached remote `tmux` sessions across saved hosts.
struct AgentsDashboardView: View {
    struct DiscoveredSession: Identifiable, Hashable {
        let hostID: UUID
        let hostLabel: String
        let session: TMuxSessionHelper.RemoteAISession
        var isCached: Bool = false

        var id: String { "\(hostID.uuidString)::\(session.sessionName)" }
    }

    private struct ScanTaskID: Equatable {
        let hostIDs: [UUID]
        let isProUnlocked: Bool
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

    struct HostScanOutcome: Sendable, Identifiable {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var liveSessions: [LiveSession] {
        sessionManager.sessions
    }

    private var deduplicatedRemoteSessions: [DiscoveredSession] {
        remoteSessions.filter { !isAlreadyOpen($0) }
    }

    private var aiSessions: [DiscoveredSession] {
        deduplicatedRemoteSessions.filter(\.session.isAISession)
    }

    private var otherTmuxSessions: [DiscoveredSession] {
        deduplicatedRemoteSessions.filter { !$0.session.isAISession }
    }

    private func isAlreadyOpen(_ item: DiscoveredSession) -> Bool {
        sessionManager.sessions.contains { live in
            live.hostID == item.hostID
                && live.aiAgentContext?.sessionName == item.session.sessionName
        }
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
        .navigationTitle("Agents")
        .toolbar {
            if proStore.isProUnlocked {
                if isScanning {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Syncing…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Syncing remote tmux sessions")
                    }
                }

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
                .tint(palette.accent)
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(palette.accent)
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
        .onAppear {
            guard proStore.isProUnlocked else { return }
            loadCachedSessionsIfNeeded()
        }
        .task(id: ScanTaskID(hostIDs: hosts.map(\.id), isProUnlocked: proStore.isProUnlocked)) {
            guard proStore.isProUnlocked else { return }
            loadCachedSessionsIfNeeded()
            await scanAllHosts()
        }
    }

    private var dashboardList: some View {
        List {
            if !liveSessions.isEmpty {
                Section("Live Sessions") {
                    ForEach(liveSessions) { live in
                        liveSessionRow(live)
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
        .listStyle(.insetGrouped)
        .refreshable {
            await scanAllHosts()
        }
        .overlay {
            if liveSessions.isEmpty && aiSessions.isEmpty && otherTmuxSessions.isEmpty && hostScanIssues.isEmpty && !isScanning {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "No Saved Hosts",
                        systemImage: "server.rack",
                        description: Text("Add an SSH host in the Hosts tab to launch and discover remote AI agents.")
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
                        .tint(palette.proBrandAmber)
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

    private func liveSessionRow(_ live: LiveSession) -> some View {
        let context = live.aiAgentContext
        let tint = context.map { AgentVisuals.agentTint(for: $0.agent) } ?? palette.accent
        let symbol = context.map { AgentVisuals.agentSymbol(for: $0.agent) } ?? "terminal.fill"
        let subtitle = liveSessionSubtitle(for: live)

        return Button {
            AppHaptics.impact(.light)
            openSessionTab(live.id)
        } label: {
            HStack(spacing: 12) {
                ProSquircleIcon(
                    symbolName: symbol,
                    tint: tint,
                    size: .row,
                    theme: theme
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
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }

                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    if dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 8) {
                            AgentActivityBadge(state: live.agentActivityState, showLabel: true)
                            resumePill(tint: tint)
                        }
                        .padding(.top, 2)
                    }
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        AgentActivityBadge(state: live.agentActivityState, showLabel: true)
                        resumePill(tint: tint)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(live.title)")
    }

    private func resumePill(tint: Color) -> some View {
        Text("Resume")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.pillFill(for: tint), in: Capsule())
    }

    private func liveSessionSubtitle(for live: LiveSession) -> String {
        if let context = live.aiAgentContext {
            return "\(context.workingDirectory) · \(context.sessionName)"
        }
        if let host = hosts.first(where: { $0.id == live.hostID }) ?? live.ephemeralHost {
            let userPart = host.username.isEmpty ? "" : "\(host.username)@"
            let portPart = host.port == 22 ? "" : ":\(host.port)"
            return "\(userPart)\(host.hostname)\(portPart)"
        }
        return live.connectionStatus.accessibilityLabel
    }

    private func remoteSessionRow(_ item: DiscoveredSession) -> some View {
        let session = item.session
        let descriptor = AgentVisuals.agentDescriptor(forSlug: session.agentSlug)
        let tint = AgentVisuals.agentTint(for: descriptor)
        let badge = session.projectSlug.isEmpty ? session.sessionName : session.projectSlug
        let statusDescription = item.isCached ? "cached" : (session.isAttached ? "attached" : "idle")
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
            accessibilityDescription: "\(descriptor.name) on \(item.hostLabel), \(statusDescription)",
            onAttach: { forceNewTab in attach(item, forceNewTab: forceNewTab) }
        )
    }

    private func otherTmuxSessionRow(_ item: DiscoveredSession) -> some View {
        let session = item.session
        let commandBadge = session.detectedCommand ?? ""
        return tmuxSessionRow(
            item: item,
            iconSymbol: "terminal",
            iconTint: palette.neutral,
            title: session.sessionName,
            badgeText: commandBadge,
            badgeTint: palette.neutral,
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
        let ledColor = item.isCached
            ? palette.neutral
            : (session.isAttached ? palette.healthy : palette.proBrandAmber)
        let activityDate = session.lastActivityAt ?? session.createdAt

        return Button {
            AppHaptics.impact(.light)
            onAttach(false)
        } label: {
            HStack(spacing: 12) {
                ProSquircleIcon(
                    symbolName: iconSymbol,
                    tint: iconTint,
                    size: .row,
                    theme: theme
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProStatusLED(color: ledColor, size: 7)

                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                        if !badgeText.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                            tmuxBadgePill(badgeText, tint: badgeTint)
                        }
                    }

                    if !badgeText.isEmpty && dynamicTypeSize.isAccessibilitySize {
                        tmuxBadgePill(badgeText, tint: badgeTint)
                    }

                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)

                    if dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 6) {
                            if item.isCached {
                                cachedBadgePill
                            } else {
                                Text(session.isAttached ? "Attached" : "Idle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ledColor)
                            }

                            if activityDate != nil {
                                Text("· \(AgentVisuals.relativeActivityString(from: activityDate))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                if !dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .trailing, spacing: 2) {
                        if item.isCached {
                            cachedBadgePill
                        } else {
                            Text(session.isAttached ? "Attached" : "Idle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ledColor)
                        }

                        if activityDate != nil {
                            Text(AgentVisuals.relativeActivityString(from: activityDate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
            .tint(palette.healthy)
        }
    }

    private var cachedBadgePill: some View {
        Text("Cached")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(palette.neutral)
            .background(palette.pillFill(for: palette.neutral), in: Capsule())
    }

    private func tmuxBadgePill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(palette.pillFill(for: tint), in: Capsule())
    }

    private func hostScanStatusRow(_ outcome: HostScanOutcome) -> some View {
        let reason = outcome.status.issueReason ?? ""
        let tint: Color = switch outcome.status {
        case .ok:
            palette.healthy
        case .tmuxMissing:
            palette.neutral
        case .needsAuthOrTrust:
            palette.proBrandAmber
        case .unreachable:
            palette.critical
        }

        return HStack(spacing: 12) {
            ProSquircleIcon(
                symbolName: outcome.status.symbolName,
                tint: tint,
                size: .compact,
                theme: theme
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.hostLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                if dynamicTypeSize.isAccessibilitySize,
                   let host = hosts.first(where: { $0.id == outcome.hostID }) {
                    connectScanIssueButton(for: host, label: outcome.hostLabel, tint: tint)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            if !dynamicTypeSize.isAccessibilitySize,
               let host = hosts.first(where: { $0.id == outcome.hostID }) {
                connectScanIssueButton(for: host, label: outcome.hostLabel, tint: tint)
            }
        }
        .padding(.vertical, 2)
    }

    private func connectScanIssueButton(for host: Host, label: String, tint: Color) -> some View {
        Button("Connect") {
            AppHaptics.impact(.light)
            connectHost?(host)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
        .accessibilityLabel("Connect to \(label)")
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
        let target = AgentHostTarget(host: host, sessionManager: sessionManager, allHosts: hosts)
        do {
            let result = try await AgentAuthHelper.exec(
                TMuxSessionHelper.killSessionCommand(sessionName: item.session.sessionName),
                on: target
            )
            guard result.exitCode == 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = !stderr.isEmpty
                    ? stderr
                    : (!stdout.isEmpty ? stdout : "Failed to kill session (exit code \(result.exitCode)).")
                AppHaptics.notify(.error)
                killError = detail
                return
            }
            AppHaptics.notify(.success)
            remoteSessions.removeAll { $0.id == item.id }
            AISessionCacheStore.remove(
                hostID: item.hostID,
                sessionName: item.session.sessionName,
                defaults: sessionManager.cacheDefaults
            )
            sessionManager.noteCacheChanged()
        } catch {
            AppHaptics.notify(.error)
            killError = error.localizedDescription
        }
    }

    private func loadCachedSessionsIfNeeded() {
        guard !hasScannedOnce else { return }
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let cached = AISessionCacheStore.load(defaults: sessionManager.cacheDefaults)
        let hydrated = cached.compactMap { entry -> DiscoveredSession? in
            guard entry.isAISession, let host = hostsByID[entry.hostID] else { return nil }
            let label = host.label.isEmpty ? host.hostname : host.label
            return Self.makeDiscoveredSession(from: entry, hostLabel: label)
        }
        remoteSessions = Self.sortedSessions(hydrated)
    }

    private func scanAllHosts() async {
        scanGeneration += 1
        let generation = scanGeneration
        let targets = hosts.map { AgentHostTarget(host: $0, sessionManager: sessionManager, allHosts: hosts) }
        let knownCommands = Self.buildKnownCommands()

        guard !targets.isEmpty else {
            remoteSessions = []
            scanOutcomes = []
            isScanning = false
            hasScannedOnce = true
            return
        }

        let targetHostIDs = Set(targets.map(\.id))
        remoteSessions.removeAll { !targetHostIDs.contains($0.hostID) }
        if !hasScannedOnce && remoteSessions.isEmpty {
            loadCachedSessionsIfNeeded()
        }

        isScanning = true
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }

        let maxConcurrentScans = 5
        let outcomes = await withTaskGroup(of: HostScanOutcome.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<min(maxConcurrentScans, targets.count) {
                if let target = iterator.next() {
                    group.addTask {
                        await Self.scanHost(target, knownCommands: knownCommands)
                    }
                }
            }

            var collected: [HostScanOutcome] = []
            collected.reserveCapacity(targets.count)
            for await outcome in group {
                collected.append(outcome)
                if !Task.isCancelled, let nextTarget = iterator.next() {
                    group.addTask {
                        await Self.scanHost(nextTarget, knownCommands: knownCommands)
                    }
                }
            }
            return collected
        }

        guard !Task.isCancelled, generation == scanGeneration else { return }

        let discovered = Self.applyScanOutcomes(
            outcomes,
            cacheDefaults: sessionManager.cacheDefaults
        )
        sessionManager.noteCacheChanged()
        remoteSessions = discovered
        scanOutcomes = outcomes
        hasScannedOnce = true
    }

    static func applyScanOutcomes(
        _ outcomes: [HostScanOutcome],
        cacheDefaults: UserDefaults,
        now: Date = .now
    ) -> [DiscoveredSession] {
        let cachedByHost = Dictionary(
            grouping: AISessionCacheStore.load(defaults: cacheDefaults),
            by: \.hostID
        )
        var discovered: [DiscoveredSession] = []

        for outcome in outcomes {
            switch outcome.status {
            case .ok:
                let discoveredCached = outcome.sessions
                    .filter(\.isAISession)
                    .map { session in
                        CachedAISession(
                            hostID: outcome.hostID,
                            hostLabel: outcome.hostLabel,
                            sessionName: session.sessionName,
                            agentSlug: session.agentSlug,
                            projectSlug: session.projectSlug,
                            currentPath: session.currentPath,
                            isTermAppManaged: session.isTermAppManaged,
                            detectedCommand: session.detectedCommand,
                            lastSeenAt: session.lastActivityAt ?? session.createdAt ?? now,
                            wasOpenInApp: false
                        )
                    }
                AISessionCacheStore.replaceRemoteSessions(
                    for: outcome.hostID,
                    with: discoveredCached,
                    defaults: cacheDefaults
                )
                for session in outcome.sessions {
                    discovered.append(
                        DiscoveredSession(
                            hostID: outcome.hostID,
                            hostLabel: outcome.hostLabel,
                            session: session,
                            isCached: false
                        )
                    )
                }

            case .tmuxMissing:
                AISessionCacheStore.removeAll(for: outcome.hostID, defaults: cacheDefaults)

            case .needsAuthOrTrust, .unreachable:
                let hostCached = (cachedByHost[outcome.hostID] ?? []).filter(\.isAISession)
                for entry in hostCached {
                    discovered.append(
                        makeDiscoveredSession(
                            from: entry,
                            hostLabel: outcome.hostLabel
                        )
                    )
                }
            }
        }

        return sortedSessions(discovered)
    }

    private static func makeDiscoveredSession(
        from entry: CachedAISession,
        hostLabel: String
    ) -> DiscoveredSession {
        let resolvedLabel = hostLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? entry.hostLabel
            : hostLabel
        let remote = TMuxSessionHelper.RemoteAISession(
            sessionName: entry.sessionName,
            agentSlug: entry.agentSlug,
            projectSlug: entry.projectSlug,
            isAttached: false,
            windowCount: 1,
            createdAt: nil,
            lastActivityAt: entry.lastSeenAt,
            currentPath: entry.currentPath,
            isTermAppManaged: entry.isTermAppManaged,
            detectedCommand: entry.detectedCommand
        )
        return DiscoveredSession(
            hostID: entry.hostID,
            hostLabel: resolvedLabel,
            session: remote,
            isCached: true
        )
    }

    private static func sortedSessions(_ sessions: [DiscoveredSession]) -> [DiscoveredSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isCached != rhs.isCached {
                return !lhs.isCached && rhs.isCached
            }
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
            return evaluateScanResult(result, target: target, knownCommands: knownCommands)
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

    nonisolated static func evaluateScanResult(
        _ result: SSHExecResult,
        target: AgentHostTarget,
        knownCommands: [String: String]
    ) -> HostScanOutcome {
        guard result.exitCode == 0 else {
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: [],
                status: .unreachable(reason: conciseScanFailureReason(for: result))
            )
        }
        if TMuxSessionHelper.isTmuxMissing(in: result.stdout) {
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: [],
                status: .tmuxMissing
            )
        }
        guard TMuxSessionHelper.hasPanesBeginMarker(in: result.stdout) else {
            return HostScanOutcome(
                hostID: target.id,
                hostLabel: target.displayName,
                sessions: [],
                status: .unreachable(reason: conciseScanFailureReason(for: result))
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
    }

    private nonisolated static func conciseScanFailureReason(for result: SSHExecResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            let firstLine = stderr
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let firstLine, !firstLine.isEmpty {
                return firstLine
            }
        }
        if result.exitCode != 0 {
            return "Remote scan failed (exit \(result.exitCode))"
        }
        return "Incomplete tmux scan response"
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
        ProFeatureGateView(
            symbolName: "sparkles",
            title: "AI Agent Sessions",
            subtitle: "Launch, monitor, and reattach Claude Code, Antigravity, Codex, Aider & OpenCode in persistent tmux sessions.",
            features: [
                ProFeatureItem(
                    icon: "terminal.fill",
                    tint: palette.proBrandAmber,
                    title: "Persistent tmux Sessions",
                    detail: "Start or reattach remote coding agents across background drops without losing context."
                ),
                ProFeatureItem(
                    icon: "folder.badge.gearshape",
                    tint: palette.running,
                    title: "Remote Folder Picker & Presets",
                    detail: "Browse server directories, star project favorites, and save custom agent CLIs."
                ),
                ProFeatureItem(
                    icon: "text.bubble.fill",
                    tint: palette.healthy,
                    title: "Quick Actions & Prompt Composer",
                    detail: "1-tap Approve, Deny, Esc, Shift+Tab, /compact, and multi-line voice-ready prompt pasting."
                ),
            ],
            theme: theme,
            onUnlock: { showingPaywall = true }
        )
    }
}
