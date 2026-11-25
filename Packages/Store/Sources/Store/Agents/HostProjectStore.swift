import Foundation

/// `UserDefaults`-backed persistence for per-host AI project paths, last-used agent, and custom presets.
public enum HostProjectStore {
    public static let storageKey = "termapp.hostProjects.v1"
    public static let maxRecentsCount = 12

    private struct HostEntry: Codable {
        var favorites: [String] = []
        var recents: [String] = []
        var lastAgentID: String?
    }

    private struct StoreState: Codable {
        var hosts: [String: HostEntry] = [:]
        var customPresets: [CustomAIAgentPreset] = []
    }

    // MARK: - Favorites

    /// Returns favorite project paths for `hostID` in saved order.
    public static func favorites(for hostID: UUID, defaults: UserDefaults = .standard) -> [String] {
        loadState(defaults: defaults).hosts[hostID.uuidString]?.favorites ?? []
    }

    /// Adds a favorite project path for `hostID`, normalizing and deduplicating in place.
    public static func addFavorite(_ path: String, for hostID: UUID, defaults: UserDefaults = .standard) {
        guard let normalized = normalizePath(path) else { return }
        var state = loadState(defaults: defaults)
        var entry = state.hosts[hostID.uuidString] ?? HostEntry()
        guard !entry.favorites.contains(normalized) else { return }
        entry.favorites.append(normalized)
        state.hosts[hostID.uuidString] = entry
        saveState(state, defaults: defaults)
    }

    /// Removes a favorite project path for `hostID` if present.
    public static func removeFavorite(_ path: String, for hostID: UUID, defaults: UserDefaults = .standard) {
        guard let normalized = normalizePath(path) else { return }
        var state = loadState(defaults: defaults)
        guard var entry = state.hosts[hostID.uuidString] else { return }
        let before = entry.favorites.count
        entry.favorites.removeAll { $0 == normalized }
        guard entry.favorites.count != before else { return }
        storeOrPruneEntry(entry, for: hostID, in: &state)
        saveState(state, defaults: defaults)
    }

    // MARK: - Recents

    /// Returns recent project paths for `hostID`, ordered most-recent-first.
    public static func recents(for hostID: UUID, defaults: UserDefaults = .standard) -> [String] {
        loadState(defaults: defaults).hosts[hostID.uuidString]?.recents ?? []
    }

    /// Records `path` as the most recently used project directory for `hostID`, capped at `maxRecentsCount`.
    public static func recordRecent(_ path: String, for hostID: UUID, defaults: UserDefaults = .standard) {
        guard let normalized = normalizePath(path) else { return }
        var state = loadState(defaults: defaults)
        var entry = state.hosts[hostID.uuidString] ?? HostEntry()
        entry.recents.removeAll { $0 == normalized }
        entry.recents.insert(normalized, at: 0)
        if entry.recents.count > maxRecentsCount {
            entry.recents = Array(entry.recents.prefix(maxRecentsCount))
        }
        state.hosts[hostID.uuidString] = entry
        saveState(state, defaults: defaults)
    }

    // MARK: - Last-Used Agent

    /// Returns the ID of the most recently used agent preset for `hostID`, if recorded.
    public static func lastAgentID(for hostID: UUID, defaults: UserDefaults = .standard) -> String? {
        loadState(defaults: defaults).hosts[hostID.uuidString]?.lastAgentID
    }

    /// Records the last-used agent preset ID for `hostID` (clearing when empty/whitespace-only).
    public static func setLastAgentID(_ id: String, for hostID: UUID, defaults: UserDefaults = .standard) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = loadState(defaults: defaults)
        var entry = state.hosts[hostID.uuidString] ?? HostEntry()
        entry.lastAgentID = trimmed.isEmpty ? nil : trimmed
        storeOrPruneEntry(entry, for: hostID, in: &state)
        saveState(state, defaults: defaults)
    }

    // MARK: - Custom Presets

    /// Returns all saved custom AI agent presets in saved order.
    public static func customPresets(defaults: UserDefaults = .standard) -> [CustomAIAgentPreset] {
        loadState(defaults: defaults).customPresets
    }

    /// Inserts `preset`, or updates an existing preset with matching `id` in place.
    public static func saveCustomPreset(_ preset: CustomAIAgentPreset, defaults: UserDefaults = .standard) {
        var state = loadState(defaults: defaults)
        if let index = state.customPresets.firstIndex(where: { $0.id == preset.id }) {
            state.customPresets[index] = preset
        } else {
            state.customPresets.append(preset)
        }
        saveState(state, defaults: defaults)
    }

    /// Deletes the custom preset with matching `id`, if present.
    public static func deleteCustomPreset(id: UUID, defaults: UserDefaults = .standard) {
        var state = loadState(defaults: defaults)
        let before = state.customPresets.count
        state.customPresets.removeAll { $0.id == id }
        guard state.customPresets.count != before else { return }
        saveState(state, defaults: defaults)
    }

    /// Returns all built-in presets followed by all saved custom presets.
    public static func allPresets(defaults: UserDefaults = .standard) -> [AIAgentDescriptor] {
        AIAgentDescriptor.builtIns + customPresets(defaults: defaults).map(AIAgentDescriptor.init(custom:))
    }

    // MARK: - Host Cleanup

    /// Removes all saved favorites, recents, and last-agent preference for `hostID`.
    public static func deleteAll(for hostID: UUID, defaults: UserDefaults = .standard) {
        var state = loadState(defaults: defaults)
        guard state.hosts.removeValue(forKey: hostID.uuidString) != nil else { return }
        saveState(state, defaults: defaults)
    }

    // MARK: - Helpers

    private static func normalizePath(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func storeOrPruneEntry(_ entry: HostEntry, for hostID: UUID, in state: inout StoreState) {
        if entry.favorites.isEmpty && entry.recents.isEmpty && entry.lastAgentID == nil {
            state.hosts.removeValue(forKey: hostID.uuidString)
        } else {
            state.hosts[hostID.uuidString] = entry
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
