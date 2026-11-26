import ActivityKit
import Foundation

/// Live Activity attributes shared between the main `TermApp` target and `TermAppWidgets` extension.
struct AgentActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        /// Status token matching `WidgetAgentStatus.rawValue`: `"running"`, `"approval"`, `"done"`, or `"idle"`.
        var status: String
        var statusMessage: String
        var updatedAt: Date
    }

    var sessionID: UUID
    var hostID: UUID
    var hostLabel: String
    var agentName: String
    var agentSlug: String
    var projectName: String
    var sessionName: String
}
