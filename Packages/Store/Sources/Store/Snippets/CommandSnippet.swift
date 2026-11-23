import Foundation

/// A saved terminal command snippet that can be injected into an active session.
public struct CommandSnippet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var appendNewline: Bool

    public init(id: UUID = UUID(), name: String, command: String, appendNewline: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.appendNewline = appendNewline
    }

    /// UTF-8 payload sent to the terminal; appends `\r` when `appendNewline` is true and `command`
    /// does not already end with `\r` or `\n`.
    public var payloadBytes: [UInt8] {
        var bytes = Array(command.utf8)
        if appendNewline, let last = bytes.last, last != 0x0D, last != 0x0A {
            bytes.append(0x0D)
        } else if appendNewline, bytes.isEmpty {
            bytes.append(0x0D)
        }
        return bytes
    }
}

/// JSON-backed persistence for user command snippets in `UserDefaults`.
public enum SnippetStore {
    public static let storageKey = "termapp.snippets.v1"

    public static let starterSnippets: [CommandSnippet] = [
        CommandSnippet(
            id: UUID(uuidString: "5A100001-0000-4000-8000-000000000001")!,
            name: "Docker PS",
            command: "docker ps"
        ),
        CommandSnippet(
            id: UUID(uuidString: "5A100001-0000-4000-8000-000000000002")!,
            name: "Git Status",
            command: "git status"
        ),
        CommandSnippet(
            id: UUID(uuidString: "5A100001-0000-4000-8000-000000000003")!,
            name: "Disk Usage",
            command: "df -h"
        ),
        CommandSnippet(
            id: UUID(uuidString: "5A100001-0000-4000-8000-000000000004")!,
            name: "System Logs",
            command: "journalctl -n 50 --no-pager"
        ),
    ]

    /// Loads saved snippets, returning `starterSnippets` if the store has never been written.
    public static func load(defaults: UserDefaults = .standard) -> [CommandSnippet] {
        guard let data = defaults.data(forKey: storageKey) else {
            return starterSnippets
        }
        return (try? JSONDecoder().decode([CommandSnippet].self, from: data)) ?? starterSnippets
    }

    /// Persists the provided snippets (including an empty array when the user deletes all snippets).
    public static func save(_ snippets: [CommandSnippet], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
