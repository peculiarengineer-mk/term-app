import AppIntents
import Foundation
import Store

/// Saved SSH host entity exposed to Siri and the Shortcuts app from App Group snapshots.
struct HostEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = HostEntityQuery()

    let id: UUID
    let displayName: String
    let hostname: String
    let username: String
    let tags: [String]

    init(
        id: UUID,
        displayName: String,
        hostname: String,
        username: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.username = username
        self.tags = tags
    }

    init(snapshot: WidgetHostSnapshot) {
        self.init(
            id: snapshot.id,
            displayName: snapshot.displayName,
            hostname: snapshot.hostname,
            username: snapshot.username,
            tags: snapshot.tags
        )
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = username.isEmpty ? hostname : "\(username)@\(hostname)"
        return DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(subtitle)"
        )
    }
}

/// Queries saved SSH hosts from `WidgetSnapshotStore` so Siri & Shortcuts work even when AmberTTY is closed.
struct HostEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        Self.entities(for: identifiers, defaults: WidgetSnapshotStore.sharedDefaults())
    }

    func entities(matching string: String) async throws -> [HostEntity] {
        Self.entities(matching: string, defaults: WidgetSnapshotStore.sharedDefaults())
    }

    func suggestedEntities() async throws -> [HostEntity] {
        Self.suggestedEntities(defaults: WidgetSnapshotStore.sharedDefaults())
    }

    static func entities(for identifiers: [UUID], defaults: UserDefaults) -> [HostEntity] {
        let snapshotsByID = Dictionary(
            uniqueKeysWithValues: WidgetSnapshotStore.loadHosts(defaults: defaults).map { ($0.id, $0) }
        )
        return identifiers.compactMap { snapshotsByID[$0] }.map(HostEntity.init(snapshot:))
    }

    static func entities(matching string: String, defaults: UserDefaults) -> [HostEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = WidgetSnapshotStore.loadHosts(defaults: defaults)
        guard !query.isEmpty else {
            return hosts.map(HostEntity.init(snapshot:))
        }
        return hosts.filter { host in
            host.displayName.localizedCaseInsensitiveContains(query)
                || host.hostname.localizedCaseInsensitiveContains(query)
                || host.username.localizedCaseInsensitiveContains(query)
                || host.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        .map(HostEntity.init(snapshot:))
    }

    static func suggestedEntities(defaults: UserDefaults) -> [HostEntity] {
        WidgetSnapshotStore.loadHosts(defaults: defaults).map(HostEntity.init(snapshot:))
    }
}

/// Supported built-in AI coding agents exposed as an AppIntents parameter enum.
enum AIAgentAppEnum: String, AppEnum, CaseIterable, Sendable {
    case claude
    case agy
    case codex
    case aider
    case opencode

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AI Agent"

    static let caseDisplayRepresentations: [AIAgentAppEnum: DisplayRepresentation] = [
        .claude: "Claude Code",
        .agy: "Antigravity",
        .codex: "Codex",
        .aider: "Aider",
        .opencode: "OpenCode",
    ]
}

/// Opens AmberTTY and connects an interactive SSH terminal tab to the selected host.
struct ConnectHostIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Host"
    static let description = IntentDescription("Opens AmberTTY and starts an SSH session on the chosen host.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Host")
    var host: HostEntity

    init() {}

    init(host: HostEntity) {
        self.host = host
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            enqueue(into: DeepLinkRouter.shared)
        }
        return .result()
    }

    @MainActor
    func enqueue(into router: DeepLinkRouter) {
        router.enqueue(.connectHost(hostID: host.id))
    }
}

/// Opens AmberTTY and launches or reattaches an AI coding agent in `tmux` on the selected host.
struct LaunchAIAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch AI Agent"
    static let description = IntentDescription("Opens AmberTTY and launches an AI coding agent in tmux on the chosen host.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Agent")
    var agent: AIAgentAppEnum

    @Parameter(title: "Host")
    var host: HostEntity

    init() {}

    init(agent: AIAgentAppEnum, host: HostEntity) {
        self.agent = agent
        self.host = host
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            enqueue(into: DeepLinkRouter.shared)
        }
        return .result()
    }

    @MainActor
    func enqueue(into router: DeepLinkRouter) {
        router.enqueue(.launchAgent(hostID: host.id, agentSlug: agent.rawValue, sessionName: nil))
    }
}

/// Opens AmberTTY and reattaches the most recently open AI agent session, or opens the Agents tab if none is cached.
struct ResumeAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume AI Agent"
    static let description = IntentDescription("Reattaches your most recent AI agent tmux session in AmberTTY.")
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            enqueue(into: DeepLinkRouter.shared)
        }
        return .result()
    }

    @MainActor
    func enqueue(into router: DeepLinkRouter, cacheDefaults: UserDefaults = .standard) {
        if let lastSession = AISessionCacheStore.lastOpenSession(defaults: cacheDefaults) {
            router.enqueue(
                .launchAgent(
                    hostID: lastSession.hostID,
                    agentSlug: lastSession.agentSlug,
                    sessionName: lastSession.sessionName
                )
            )
        } else {
            router.enqueue(.openAgentsTab)
        }
    }
}

/// Exposes natural Siri & Shortcuts phrases for AmberTTY SSH and AI Agent workflows.
struct TermAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectHostIntent(),
            phrases: [
                "Connect to a host in \(.applicationName)",
                "SSH to a host in \(.applicationName)"
            ],
            shortTitle: "Connect to Host",
            systemImageName: "server.rack"
        )

        AppShortcut(
            intent: LaunchAIAgentIntent(),
            phrases: [
                "Launch an AI agent in \(.applicationName)",
                "Launch \(\.$agent) in \(.applicationName)"
            ],
            shortTitle: "Launch AI Agent",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ResumeAgentIntent(),
            phrases: [
                "Resume AI agent in \(.applicationName)",
                "Resume my AI agent in \(.applicationName)"
            ],
            shortTitle: "Resume AI Agent",
            systemImageName: "arrow.clockwise.circle.fill"
        )
    }
}
