import Foundation
import SwiftData

/// A saved SSH host. Holds IDs only (`keyID` points at a Keychain item), never secret bytes.
/// CloudKit-compatible: every attribute defaulted or optional, no unique constraints.
@Model
public final class Host {
    public var id: UUID = UUID()
    public var label: String = ""
    public var hostname: String = ""
    public var port: Int = 22
    public var username: String = ""
    /// Raw string: "password", "key" or "keyboardInteractive".
    public var authMethod: String = "password"
    public var keyID: UUID?
    public var tmuxCommand: String?
    public var tags: [String] = []
    public var source: String = "manual"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    /// Assigned once per insert, never changed; tie-break when deduplicating synced copies.
    public var copyID: UUID = UUID()

    public init(
        id: UUID = UUID(),
        label: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: String = "password",
        keyID: UUID? = nil,
        tmuxCommand: String? = nil,
        tags: [String] = [],
        source: String = "manual",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        copyID: UUID = UUID()
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyID = keyID
        self.tmuxCommand = tmuxCommand
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.copyID = copyID
    }

    public func touch() { updatedAt = .now }
}
