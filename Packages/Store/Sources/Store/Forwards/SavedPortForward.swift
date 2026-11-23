import Foundation

/// A saved SSH local port-forwarding rule (`-L`) associated with a `Host` ID.
public struct SavedPortForward: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var name: String
    /// Local bind port; `0` requests an ephemeral auto-assigned local port.
    public var localPort: UInt16
    public var remoteHost: String
    public var remotePort: UInt16
    public var autoStart: Bool

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        name: String = "",
        localPort: UInt16,
        remoteHost: String = "127.0.0.1",
        remotePort: UInt16,
        autoStart: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoStart = autoStart
    }

    /// Display label for UI lists: trimmed `name` if non-empty, otherwise `"<remoteHost>:<remotePort>"`.
    public var displayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(remoteHost):\(remotePort)" : trimmed
    }

    /// Human-readable route summary showing local bind port (`auto` when `0`) and remote target.
    public var routeDescription: String {
        "localhost:\(localPort == 0 ? "auto" : String(localPort)) → \(remoteHost):\(remotePort)"
    }
}

/// JSON-backed persistence for saved port-forward rules in `UserDefaults`.
public enum PortForwardStore {
    public static let storageKey = "termapp.forwards.v1"

    /// Returns all saved port-forward rules across all hosts, or `[]` when empty or unreadable.
    public static func all(defaults: UserDefaults = .standard) -> [SavedPortForward] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([SavedPortForward].self, from: data)) ?? []
    }

    /// Returns saved port-forward rules belonging to `hostID`, preserving stored order.
    public static func list(for hostID: UUID, defaults: UserDefaults = .standard) -> [SavedPortForward] {
        all(defaults: defaults).filter { $0.hostID == hostID }
    }

    /// Inserts `forward`, or replaces the existing rule with matching `id` in place.
    public static func upsert(_ forward: SavedPortForward, defaults: UserDefaults = .standard) {
        var forwards = all(defaults: defaults)
        if let index = forwards.firstIndex(where: { $0.id == forward.id }) {
            forwards[index] = forward
        } else {
            forwards.append(forward)
        }
        save(forwards, defaults: defaults)
    }

    /// Deletes the rule with the given `id`, if present.
    public static func delete(id: UUID, defaults: UserDefaults = .standard) {
        var forwards = all(defaults: defaults)
        let beforeCount = forwards.count
        forwards.removeAll { $0.id == id }
        guard forwards.count != beforeCount else { return }
        save(forwards, defaults: defaults)
    }

    /// Deletes every rule associated with `hostID`.
    public static func deleteAll(for hostID: UUID, defaults: UserDefaults = .standard) {
        var forwards = all(defaults: defaults)
        let beforeCount = forwards.count
        forwards.removeAll { $0.hostID == hostID }
        guard forwards.count != beforeCount else { return }
        save(forwards, defaults: defaults)
    }

    private static func save(_ forwards: [SavedPortForward], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(forwards) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
