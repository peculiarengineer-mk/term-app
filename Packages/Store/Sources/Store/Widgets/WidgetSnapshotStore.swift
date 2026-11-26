import Foundation

/// Lightweight, `Sendable` snapshot of a saved SSH host shared with widgets and App Intents via App Group `UserDefaults`.
public struct WidgetHostSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var hostname: String
    public var username: String
    public var tags: [String]
    public var lastConnectedAt: Date?
    public var source: String?

    /// Display label for widgets and intents: trimmed `label` if non-empty, otherwise `hostname`.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostname : trimmed
    }

    public init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        username: String,
        tags: [String] = [],
        lastConnectedAt: Date? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.username = username
        self.tags = tags
        self.lastConnectedAt = lastConnectedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case hostname
        case username
        case tags
        case lastConnectedAt
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        hostname = try container.decode(String.self, forKey: .hostname)
        username = try container.decode(String.self, forKey: .username)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

/// High-level execution state of an AI agent session for widgets and Live Activities.
public enum WidgetAgentStatus: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case running
    case approval
    case done
    case idle

    /// Human-readable status label rendered in widgets and Live Activities.
    public var displayTitle: String {
        switch self {
        case .running: "Running"
        case .approval: "Approval"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}

/// Lightweight, `Sendable` snapshot of an AI agent session shared with widgets, Live Activities, and App Intents.
public struct WidgetAgentSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(hostID.uuidString):\(sessionName)" }
    /// Live in-app session UUID if currently open; `nil` when cached or detached.
    public let sessionID: UUID?
    public let hostID: UUID
    public var hostLabel: String
    public let sessionName: String
    public var agentSlug: String
    public var agentName: String
    public var projectSlug: String
    public var status: WidgetAgentStatus
    public var promptSnippet: String?
    public var updatedAt: Date

    public init(
        sessionID: UUID? = nil,
        hostID: UUID,
        hostLabel: String,
        sessionName: String,
        agentSlug: String,
        agentName: String,
        projectSlug: String,
        status: WidgetAgentStatus,
        promptSnippet: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.hostLabel = hostLabel
        self.sessionName = sessionName
        self.agentSlug = agentSlug
        self.agentName = agentName
        self.projectSlug = projectSlug
        self.status = status
        self.promptSnippet = promptSnippet
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case hostID
        case hostLabel
        case sessionName
        case agentSlug
        case agentName
        case projectSlug
        case status
        case promptSnippet
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        hostLabel = try container.decode(String.self, forKey: .hostLabel)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        agentSlug = try container.decode(String.self, forKey: .agentSlug)
        agentName = try container.decode(String.self, forKey: .agentName)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        status = try container.decode(WidgetAgentStatus.self, forKey: .status)
        promptSnippet = try container.decodeIfPresent(String.self, forKey: .promptSnippet)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// App Group `UserDefaults`-backed storage for host and AI agent snapshots consumed by extensions.
public enum WidgetSnapshotStore {
    public static let appGroupID = "group.com.peculiarengineer.termapp"
    public static let hostsStorageKey = "termapp.widget.hosts.v1"
    public static let agentsStorageKey = "termapp.widget.agents.v1"

    /// Returns the shared App Group `UserDefaults` suite, falling back to `.standard` if unavailable.
    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// Persists host snapshots under `hostsStorageKey`.
    public static func saveHosts(_ hosts: [WidgetHostSnapshot], defaults: UserDefaults = sharedDefaults()) {
        save(hosts, forKey: hostsStorageKey, defaults: defaults)
    }

    /// Loads persisted host snapshots, returning `[]` when empty or unreadable.
    public static func loadHosts(defaults: UserDefaults = sharedDefaults()) -> [WidgetHostSnapshot] {
        load([WidgetHostSnapshot].self, forKey: hostsStorageKey, defaults: defaults)
    }

    /// Persists agent snapshots under `agentsStorageKey`.
    public static func saveAgents(_ agents: [WidgetAgentSnapshot], defaults: UserDefaults = sharedDefaults()) {
        save(agents, forKey: agentsStorageKey, defaults: defaults)
    }

    /// Loads persisted agent snapshots, returning `[]` when empty or unreadable.
    public static func loadAgents(defaults: UserDefaults = sharedDefaults()) -> [WidgetAgentSnapshot] {
        load([WidgetAgentSnapshot].self, forKey: agentsStorageKey, defaults: defaults)
    }

    private static func save<T: Encodable>(_ items: [T], forKey key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: [T].Type, forKey key: String, defaults: UserDefaults) -> [T] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode(type, from: data)) ?? []
    }
}

/// Type-safe `termapp://` deep-link routes shared between the main app, widgets, Live Activities, and App Intents.
public enum TermAppDeepLink: Equatable, Hashable, Sendable {
    case connectHost(hostID: UUID)
    case launchAgent(hostID: UUID, agentSlug: String?, sessionName: String?)
    case focusSession(sessionID: UUID)
    case openAgentsTab

    public static let scheme = "termapp"

    /// Encodes this deep link as a `termapp://` URL.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .connectHost(let hostID):
            components.host = "host"
            components.path = "/\(hostID.uuidString)"

        case .launchAgent(let hostID, let agentSlug, let sessionName):
            components.host = "agent"
            components.path = "/\(hostID.uuidString)"
            var queryItems: [URLQueryItem] = []
            if let agentSlug, !agentSlug.isEmpty {
                queryItems.append(URLQueryItem(name: "agent", value: agentSlug))
            }
            if let sessionName, !sessionName.isEmpty {
                queryItems.append(URLQueryItem(name: "session", value: sessionName))
            }
            components.queryItems = queryItems.isEmpty ? nil : queryItems

        case .focusSession(let sessionID):
            components.host = "session"
            components.path = "/\(sessionID.uuidString)"

        case .openAgentsTab:
            components.host = "agents"
        }

        guard let builtURL = components.url else {
            preconditionFailure("Failed to build TermAppDeepLink URL for \(self)")
        }
        return builtURL
    }

    /// Parses a `termapp://` URL into a validated `TermAppDeepLink`, returning `nil` for unsupported or malformed URLs.
    public static func parse(_ url: URL) -> TermAppDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == Self.scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let route = components.host?.lowercased(),
              !route.isEmpty
        else {
            return nil
        }

        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch route {
        case "host":
            guard pathSegments.count == 1, let hostID = UUID(uuidString: pathSegments[0]) else {
                return nil
            }
            return .connectHost(hostID: hostID)

        case "agent":
            guard pathSegments.count == 1, let hostID = UUID(uuidString: pathSegments[0]) else {
                return nil
            }
            let agentSlug = firstNonEmptyQueryValue(named: "agent", in: components.queryItems)
            let sessionName = firstNonEmptyQueryValue(named: "session", in: components.queryItems)
            return .launchAgent(hostID: hostID, agentSlug: agentSlug, sessionName: sessionName)

        case "session":
            guard pathSegments.count == 1, let sessionID = UUID(uuidString: pathSegments[0]) else {
                return nil
            }
            return .focusSession(sessionID: sessionID)

        case "agents":
            guard pathSegments.isEmpty else {
                return nil
            }
            return .openAgentsTab

        default:
            return nil
        }
    }

    private static func firstNonEmptyQueryValue(named name: String, in queryItems: [URLQueryItem]?) -> String? {
        guard let queryItems else { return nil }
        for item in queryItems where item.name.lowercased() == name {
            if let value = item.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
