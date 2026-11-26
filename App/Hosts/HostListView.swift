import SwiftUI
import SwiftData
import Store
import TermUI

struct QuickConnectTarget: Equatable, Sendable {
    let user: String
    let host: String
    let port: Int

    var display: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }

    static func parse(_ input: String) -> QuickConnectTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        if tokens[0].lowercased() == "ssh" {
            tokens.removeFirst()
            guard !tokens.isEmpty else { return nil }
        }

        var flagPort: Int?
        var endpointToken: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-p" {
                guard flagPort == nil, index + 1 < tokens.count,
                      let parsedPort = validPort(tokens[index + 1]) else {
                    return nil
                }
                flagPort = parsedPort
                index += 2
            } else if token.hasPrefix("-p"), token.count > 2 {
                guard flagPort == nil,
                      let parsedPort = validPort(String(token.dropFirst(2))) else {
                    return nil
                }
                flagPort = parsedPort
                index += 1
            } else if token.hasPrefix("-") {
                return nil
            } else {
                guard endpointToken == nil else { return nil }
                endpointToken = token
                index += 1
            }
        }

        guard let endpointToken,
              let parsedEndpoint = parseEndpoint(endpointToken) else {
            return nil
        }

        if let flagPort, let inlinePort = parsedEndpoint.port, flagPort != inlinePort {
            return nil
        }

        let resolvedPort = flagPort ?? parsedEndpoint.port ?? 22
        return QuickConnectTarget(user: parsedEndpoint.user, host: parsedEndpoint.host, port: resolvedPort)
    }

    private static func parseEndpoint(_ token: String) -> (user: String, host: String, port: Int?)? {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let user = String(parts[0])
        let hostAndPort = String(parts[1])
        guard !user.isEmpty, !hostAndPort.isEmpty else { return nil }

        if hostAndPort.hasPrefix("[") {
            guard let closeBracket = hostAndPort.firstIndex(of: "]") else { return nil }
            let host = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<closeBracket])
            guard !host.isEmpty else { return nil }
            let remainder = hostAndPort[hostAndPort.index(after: closeBracket)...]
            if remainder.isEmpty {
                return (user, host, nil)
            }
            guard remainder.hasPrefix(":"),
                  let port = validPort(String(remainder.dropFirst())) else {
                return nil
            }
            return (user, host, port)
        }

        let hostParts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
        switch hostParts.count {
        case 1:
            return (user, hostAndPort, nil)
        case 2:
            let host = String(hostParts[0])
            guard !host.isEmpty, let port = validPort(String(hostParts[1])) else { return nil }
            return (user, host, port)
        default:
            return nil
        }
    }

    private static func validPort(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber),
              let port = Int(raw), (1...65535).contains(port) else {
            return nil
        }
        return port
    }
}

struct HostListView: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionManager.self) private var manager
    @Environment(ProStore.self) private var proStore
    @Environment(\.openSessionTab) private var openSessionTab
    @Environment(\.connectHost) private var connectHost
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var hosts: [Host]
    @State private var search = ""
    @State private var selectedTag: String?
    @State private var editing: Host?
    @State private var adding = false
    @State private var importingConfig = false
    @State private var agentLaunchHost: Host?
    @State private var showingPaywall = false
    @State private var deletingHost: Host?
    @State private var deleteError: String?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var quickConnectTarget: QuickConnectTarget? {
        QuickConnectTarget.parse(search)
    }

    private var allTags: [String] {
        let cleaned = hosts.flatMap { normalizedTags(for: $0) }
        return Set(cleaned).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var activeTag: String? {
        guard let selectedTag, allTags.contains(selectedTag) else { return nil }
        return selectedTag
    }

    private var filtered: [Host] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return hosts.filter { host in
            if let activeTag, !normalizedTags(for: host).contains(activeTag) {
                return false
            }
            guard !q.isEmpty else { return true }
            return host.label.localizedCaseInsensitiveContains(q)
                || host.hostname.localizedCaseInsensitiveContains(q)
                || host.username.localizedCaseInsensitiveContains(q)
                || normalizedTags(for: host).contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private var sessionsByHost: [UUID: [LiveSession]] {
        Dictionary(grouping: manager.sessions, by: \.hostID)
    }

    private var connectedHosts: [Host] {
        filtered.filter { !(sessionsByHost[$0.id] ?? []).isEmpty }
    }

    private var otherHosts: [Host] {
        filtered.filter { (sessionsByHost[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        hostsContent
            .navigationTitle("Hosts")
            .sheet(isPresented: $adding) { NavigationStack { HostEditorView(host: nil) } }
            .sheet(isPresented: $importingConfig) { SSHConfigImportView() }
            .sheet(item: $editing) { host in NavigationStack { HostEditorView(host: host) } }
            .sheet(item: $agentLaunchHost) { host in
                LaunchAIAgentSheet(initialHost: host)
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(palette.accent)
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView()
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(palette.accent)
            }
            .alert("Error", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK") {}
            } message: { Text(deleteError ?? "") }
            .confirmationDialog(
                "Delete host?",
                isPresented: Binding(
                    get: { deletingHost != nil },
                    set: { if !$0 { deletingHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletingHost
            ) { host in
                Button("Delete Host", role: .destructive) {
                    delete(host)
                }
                Button("Cancel", role: .cancel) {}
            } message: { host in
                let name = host.label.isEmpty ? host.hostname : host.label
                Text("Deleting \"\(name)\" will also remove its saved password, port-forward rules, and project presets.")
            }
    }

    private var hostsContent: some View {
        List {
            if let target = quickConnectTarget {
                Section("Quick Connect") {
                    quickConnectRow(for: target)
                }
            }

            if !connectedHosts.isEmpty {
                Section("Connected") {
                    ForEach(connectedHosts) { host in
                        hostRow(host, liveSessions: sessionsByHost[host.id] ?? [])
                    }
                }
                if !otherHosts.isEmpty {
                    Section("Hosts") {
                        ForEach(otherHosts) { host in
                            hostRow(host, liveSessions: [])
                        }
                    }
                }
            } else {
                ForEach(filtered) { host in
                    hostRow(host, liveSessions: [])
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !allTags.isEmpty {
                tagFilterBar
            }
        }
        .overlay {
            if quickConnectTarget == nil {
                if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add an SSH server manually or import your existing ~/.ssh/config.")
                    } actions: {
                        Button {
                            AppHaptics.impact(.light)
                            adding = true
                        } label: {
                            Label("Add Host", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)

                        Button {
                            AppHaptics.impact(.light)
                            importingConfig = true
                        } label: {
                            Label("Import ~/.ssh/config", systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No matching hosts",
                        systemImage: "magnifyingglass",
                        description: Text("Try clearing the search or tag filter.")
                    )
                }
            }
        }
        .searchable(text: $search, prompt: "Search or ssh user@host")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("New Host", systemImage: "plus") { adding = true }
                    Button("Import ~/.ssh/config…", systemImage: "doc.text") { importingConfig = true }
                }
            }
        }
        .onChange(of: allTags) { _, tags in
            if let selectedTag, !tags.contains(selectedTag) {
                self.selectedTag = nil
            }
        }
    }

    private func quickConnectRow(for target: QuickConnectTarget) -> some View {
        Button {
            AppHaptics.impact(.light)
            let ephemeral = Host(
                label: target.host,
                hostname: target.host,
                port: target.port,
                username: target.user,
                authMethod: "password"
            )
            connectHost?(ephemeral)
        } label: {
            HStack(spacing: 12) {
                ProSquircleIcon(
                    symbolName: "terminal.fill",
                    tint: palette.proBrandAmber,
                    size: .row,
                    theme: theme
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to \(target.display)")
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text("Ad-hoc SSH session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(palette.proBrandAmber)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    private var tagFilterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagPill(title: "All", isSelected: activeTag == nil) {
                        AppHaptics.impact(.light)
                        selectedTag = nil
                    }
                    ForEach(allTags, id: \.self) { tag in
                        tagPill(title: tag, isSelected: activeTag == tag) {
                            AppHaptics.impact(.light)
                            selectedTag = (activeTag == tag) ? nil : tag
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Divider()
        }
        .background(.bar)
    }

    private func tagPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? palette.accent : Color.primary)
                .background(
                    isSelected
                        ? palette.pillFill(for: palette.accent)
                        : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? palette.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func hostRow(_ host: Host, liveSessions: [LiveSession]) -> some View {
        let tags = normalizedTags(for: host)
        let status = aggregateStatus(for: liveSessions)
        let activityState = prioritizedAgentActivityState(for: liveSessions)

        return Button {
            AppHaptics.impact(.light)
            if let existing = liveSessions.first(where: { $0.connectionStatus == .connected }) ?? liveSessions.first {
                openSessionTab(existing.id)
            } else {
                connectHost?(host)
            }
        } label: {
            HStack(spacing: 12) {
                HostEnvironmentIcon(host: host)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(host.label.isEmpty ? host.hostname : host.label)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                        if activityState != .idle {
                            AgentActivityBadge(state: activityState)
                                .fixedSize()
                        }
                    }

                    Text(connectionSubtitle(for: host))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text(metadataLine(for: host, tags: tags))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    if dynamicTypeSize.isAccessibilitySize, let status {
                        statusIndicator(status: status, sessions: liveSessions, showChevron: false)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                if let status {
                    if dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    } else {
                        statusIndicator(status: status, sessions: liveSessions, showChevron: true)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button("New Session", systemImage: "plus.rectangle.on.rectangle") {
                AppHaptics.impact(.light)
                connectHost?(host)
            }
            Button("Launch AI Agent…", systemImage: "sparkles") {
                AppHaptics.impact(.light)
                openAIAgentLauncher(for: host)
            }
            Button("Edit", systemImage: "pencil") { editing = host }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingHost = host }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                AppHaptics.impact(.light)
                connectHost?(host)
            } label: {
                Label("New Session", systemImage: "plus.rectangle.on.rectangle")
            }
            .tint(palette.healthy)

            Button {
                AppHaptics.impact(.light)
                openAIAgentLauncher(for: host)
            } label: {
                Label("AI Agent", systemImage: "sparkles")
            }
            .tint(palette.proBrandAmber)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deletingHost = host } label: { Label("Delete", systemImage: "trash") }
            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
        }
    }

    private func prioritizedAgentActivityState(for sessions: [LiveSession]) -> AgentActivityState {
        if let approval = sessions.first(where: {
            if case .waitingForApproval = $0.agentActivityState { return true }
            return false
        }) {
            return approval.agentActivityState
        }
        if sessions.contains(where: { $0.agentActivityState == .running }) {
            return .running
        }
        if sessions.contains(where: { $0.agentActivityState == .completed }) {
            return .completed
        }
        return .idle
    }

    private func statusIndicator(
        status: LiveSession.ConnectionStatus,
        sessions: [LiveSession],
        showChevron: Bool
    ) -> some View {
        HStack(spacing: 6) {
            ConnectionStatusDot(status: status, size: 7, glow: true)
            Text(statusLabel(for: status, sessions: sessions))
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor(for: status))
                .fixedSize()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func aggregateStatus(for sessions: [LiveSession]) -> LiveSession.ConnectionStatus? {
        guard !sessions.isEmpty else { return nil }
        if sessions.contains(where: { $0.connectionStatus == .connected }) { return .connected }
        if sessions.contains(where: { $0.connectionStatus == .reconnecting }) { return .reconnecting }
        return .disconnected
    }

    private func statusColor(for status: LiveSession.ConnectionStatus) -> Color {
        switch status {
        case .connected: palette.healthy
        case .reconnecting: palette.warning
        case .disconnected: palette.critical
        }
    }

    private func statusLabel(for status: LiveSession.ConnectionStatus, sessions: [LiveSession]) -> String {
        switch status {
        case .connected:
            let connectedCount = sessions.count(where: { $0.connectionStatus == .connected })
            return connectedCount <= 1 ? "Connected" : "\(connectedCount) connected"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        }
    }

    private func metadataLine(for host: Host, tags: [String]) -> String {
        var parts = [authBadgeLabel(for: host.authMethod)]
        if host.tmuxCommand != nil {
            parts.append("tmux")
        }
        parts.append(contentsOf: tags.prefix(2))
        return parts.joined(separator: " · ")
    }

    private func normalizedTags(for host: Host) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in host.tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private func connectionSubtitle(for host: Host) -> String {
        let userPart = host.username.isEmpty ? "" : "\(host.username)@"
        let portPart = host.port == 22 ? "" : ":\(host.port)"
        return "\(userPart)\(host.hostname)\(portPart)"
    }

    private func authBadgeLabel(for method: String) -> String {
        switch method {
        case "key": "Key"
        case "password": "Password"
        case "keyboardInteractive": "2FA"
        default: method
        }
    }

    private func openAIAgentLauncher(for host: Host) {
        if proStore.isProUnlocked {
            agentLaunchHost = host
        } else {
            showingPaywall = true
        }
    }

    private func delete(_ host: Host) {
        deletingHost = nil
        let hostID = host.id
        context.delete(host)
        do {
            try context.save()
        } catch {
            context.rollback()
            deleteError = "Could not delete host: \(error.localizedDescription)"
            return
        }
        let matchingSessionIDs = manager.sessions.filter { $0.hostID == hostID }.map(\.id)
        for sessionID in matchingSessionIDs {
            manager.close(sessionID)
        }
        PortForwardStore.deleteAll(for: hostID)
        HostProjectStore.deleteAll(for: hostID)
        AISessionCacheStore.removeAll(for: hostID, defaults: manager.cacheDefaults)
        manager.noteCacheChanged()
        do {
            try HostSecrets.tryDeletePassword(for: hostID)
            AppHaptics.notify(.warning)
        } catch {
            deleteError = "Host deleted, but its saved password could not be removed: \(error.localizedDescription)"
        }
    }
}
