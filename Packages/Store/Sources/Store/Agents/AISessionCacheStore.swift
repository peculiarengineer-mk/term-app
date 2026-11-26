import Foundation

/// Persisted snapshot of an active or last-known remote `tmux` AI session for instant display and reattach.
public struct CachedAISession: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(hostID.uuidString):\(sessionName)" }
    public let hostID: UUID
    public var hostLabel: String
    public let sessionName: String
    public var agentSlug: String
    public var projectSlug: String
    public var currentPath: String?
    public var isTermAppManaged: Bool
    public var detectedCommand: String?
    public var lastSeenAt: Date
    public var wasOpenInApp: Bool

    /// `true` for TermApp-managed sessions or any `tmux` session running a recognized AI CLI.
    public var isAISession: Bool {
        isTermAppManaged || !agentSlug.isEmpty
    }

    public init(
        hostID: UUID,
        hostLabel: String,
        sessionName: String,
        agentSlug: String,
        projectSlug: String,
        currentPath: String? = nil,
        isTermAppManaged: Bool = true,
        detectedCommand: String? = nil,
        lastSeenAt: Date = Date(),
        wasOpenInApp: Bool = false
    ) {
        self.hostID = hostID
        self.hostLabel = hostLabel
        self.sessionName = sessionName
        self.agentSlug = agentSlug
        self.projectSlug = projectSlug
        self.currentPath = currentPath
        self.isTermAppManaged = isTermAppManaged
        self.detectedCommand = detectedCommand
        self.lastSeenAt = lastSeenAt
        self.wasOpenInApp = wasOpenInApp
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case hostLabel
        case sessionName
        case agentSlug
        case projectSlug
        case currentPath
        case isTermAppManaged
        case detectedCommand
        case lastSeenAt
        case wasOpenInApp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        hostLabel = try container.decode(String.self, forKey: .hostLabel)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        agentSlug = try container.decode(String.self, forKey: .agentSlug)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        currentPath = try container.decodeIfPresent(String.self, forKey: .currentPath)
        isTermAppManaged = try container.decodeIfPresent(Bool.self, forKey: .isTermAppManaged)
            ?? sessionName.hasPrefix(TMuxSessionHelper.sessionPrefix)
        detectedCommand = try container.decodeIfPresent(String.self, forKey: .detectedCommand)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        wasOpenInApp = try container.decodeIfPresent(Bool.self, forKey: .wasOpenInApp) ?? false
    }
}

/// `UserDefaults`-backed persistence for active/cached AI `tmux` sessions across app restarts.
public enum AISessionCacheStore {
    public static let storageKey = "termapp.aiSessionCache.v1"

    private struct StoreState: Codable {
        var sessions: [CachedAISession] = []
    }

    /// Returns all cached sessions sorted most-recent `lastSeenAt` first.
    public static func load(defaults: UserDefaults = .standard) -> [CachedAISession] {
        sorted(loadState(defaults: defaults).sessions)
    }

    /// Inserts or updates a cached session keyed by `(hostID, sessionName)`.
    public static func upsert(_ session: CachedAISession, defaults: UserDefaults = .standard) {
        guard !session.sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var state = loadState(defaults: defaults)
        if let index = state.sessions.firstIndex(where: { $0.hostID == session.hostID && $0.sessionName == session.sessionName }) {
            state.sessions[index] = session
        } else {
            state.sessions.append(session)
        }
        state.sessions = sorted(state.sessions)
        saveState(state, defaults: defaults)
    }

    /// Replaces cached entries for `hostID`, preserving `wasOpenInApp = true` for sessions still present on the server.
    public static func replaceRemoteSessions(
        for hostID: UUID,
        with sessions: [CachedAISession],
        defaults: UserDefaults = .standard
    ) {
        var state = loadState(defaults: defaults)
        let previouslyOpenNames = Set(
            state.sessions
                .filter { $0.hostID == hostID && $0.wasOpenInApp }
                .map(\.sessionName)
        )

        var merged = state.sessions.filter { $0.hostID != hostID }
        var deduplicatedForHost: [String: CachedAISession] = [:]

        for incoming in sessions where incoming.hostID == hostID {
            guard !incoming.sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var updated = incoming
            if previouslyOpenNames.contains(incoming.sessionName) {
                updated.wasOpenInApp = true
            }
            if let existing = deduplicatedForHost[incoming.sessionName] {
                let isOpen = existing.wasOpenInApp || updated.wasOpenInApp
                var winner = updated.lastSeenAt >= existing.lastSeenAt ? updated : existing
                winner.wasOpenInApp = isOpen
                deduplicatedForHost[incoming.sessionName] = winner
            } else {
                deduplicatedForHost[incoming.sessionName] = updated
            }
        }

        merged.append(contentsOf: deduplicatedForHost.values)
        state.sessions = sorted(merged)
        saveState(state, defaults: defaults)
    }

    /// Updates `wasOpenInApp` for the cached session matching `(hostID, sessionName)`, if present.
    public static func markOpenInApp(
        _ isOpen: Bool,
        hostID: UUID,
        sessionName: String,
        defaults: UserDefaults = .standard
    ) {
        var state = loadState(defaults: defaults)
        var changed = false
        for index in state.sessions.indices
            where state.sessions[index].hostID == hostID && state.sessions[index].sessionName == sessionName {
            if state.sessions[index].wasOpenInApp != isOpen {
                state.sessions[index].wasOpenInApp = isOpen
                changed = true
            }
        }
        guard changed else { return }
        saveState(state, defaults: defaults)
    }

    /// Removes the cached session matching `(hostID, sessionName)`, if present.
    public static func remove(hostID: UUID, sessionName: String, defaults: UserDefaults = .standard) {
        var state = loadState(defaults: defaults)
        let before = state.sessions.count
        state.sessions.removeAll { $0.hostID == hostID && $0.sessionName == sessionName }
        guard state.sessions.count != before else { return }
        saveState(state, defaults: defaults)
    }

    /// Removes all cached sessions for `hostID`.
    public static func removeAll(for hostID: UUID, defaults: UserDefaults = .standard) {
        var state = loadState(defaults: defaults)
        let before = state.sessions.count
        state.sessions.removeAll { $0.hostID == hostID }
        guard state.sessions.count != before else { return }
        saveState(state, defaults: defaults)
    }

    /// Returns cached sessions where `wasOpenInApp == true`, sorted most-recent `lastSeenAt` first.
    public static func openInAppSessions(defaults: UserDefaults = .standard) -> [CachedAISession] {
        load(defaults: defaults).filter(\.wasOpenInApp)
    }

    /// Returns the most recently seen cached session with `wasOpenInApp == true`, if any.
    public static func lastOpenSession(defaults: UserDefaults = .standard) -> CachedAISession? {
        openInAppSessions(defaults: defaults).first
    }

    // MARK: - Helpers

    private static func sorted(_ sessions: [CachedAISession]) -> [CachedAISession] {
        sessions.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            let hostOrder = lhs.hostLabel.localizedCaseInsensitiveCompare(rhs.hostLabel)
            if hostOrder != .orderedSame {
                return hostOrder == .orderedAscending
            }
            let nameOrder = lhs.sessionName.localizedCaseInsensitiveCompare(rhs.sessionName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func loadState(defaults: UserDefaults) -> StoreState {
        guard let data = defaults.data(forKey: storageKey) else {
            return StoreState()
        }
        return (try? JSONDecoder().decode(StoreState.self, from: data)) ?? StoreState()
    }

    private static func saveState(_ state: StoreState, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
