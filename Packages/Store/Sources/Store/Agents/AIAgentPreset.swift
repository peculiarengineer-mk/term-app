import Foundation

/// Built-in AI coding agent presets supported by TermApp.
public enum BuiltInAIAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case agy
    case codex
    case aider
    case opencode

    public var id: String { rawValue }

    /// Human-readable agent name shown in UI pickers and session titles.
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .agy: "Antigravity"
        case .codex: "Codex"
        case .aider: "Aider"
        case .opencode: "OpenCode"
        }
    }

    /// CLI executable name invoked on the remote host.
    public var command: String {
        rawValue
    }

    /// SF Symbol name representing this agent.
    public var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .agy: "wand.and.stars"
        case .codex: "cpu"
        case .aider: "wrench.and.screwdriver"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Semantic color token used by the UI layer to style this agent's badge/accent.
    public var colorToken: String {
        switch self {
        case .claude: "amber"
        case .agy: "cyan"
        case .codex: "green"
        case .aider: "blue"
        case .opencode: "purple"
        }
    }
}

/// User-defined AI agent preset persisted locally via `HostProjectStore`.
public struct CustomAIAgentPreset: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var command: String
    public var defaultArgs: String
    public var symbolName: String

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        defaultArgs: String = "",
        symbolName: String = "terminal"
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.defaultArgs = defaultArgs
        self.symbolName = symbolName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case defaultArgs
        case symbolName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        defaultArgs = try container.decodeIfPresent(String.self, forKey: .defaultArgs) ?? ""
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "terminal"
    }
}

/// Unified descriptor representing either a built-in or user-defined AI agent preset.
public struct AIAgentDescriptor: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var slug: String
    public var name: String
    public var command: String
    public var defaultArgs: String
    public var symbolName: String
    public var colorToken: String
    public var isBuiltIn: Bool
    public var builtIn: BuiltInAIAgent?

    public init(
        id: String,
        slug: String,
        name: String,
        command: String,
        defaultArgs: String = "",
        symbolName: String = "terminal",
        colorToken: String = "slate",
        isBuiltIn: Bool,
        builtIn: BuiltInAIAgent? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.command = command
        self.defaultArgs = defaultArgs
        self.symbolName = symbolName
        self.colorToken = colorToken
        self.isBuiltIn = isBuiltIn
        self.builtIn = builtIn
    }

    /// Creates a descriptor from a built-in agent preset.
    public init(builtIn: BuiltInAIAgent) {
        self.init(
            id: builtIn.id,
            slug: builtIn.rawValue,
            name: builtIn.displayName,
            command: builtIn.command,
            defaultArgs: "",
            symbolName: builtIn.symbolName,
            colorToken: builtIn.colorToken,
            isBuiltIn: true,
            builtIn: builtIn
        )
    }

    /// Creates a descriptor from a user-defined custom preset.
    public init(custom: CustomAIAgentPreset) {
        let trimmedName = custom.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = custom.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let slugSource = trimmedName.isEmpty ? trimmedCommand : trimmedName
        let derivedSlug = TMuxSessionHelper.sanitizeSlug(slugSource, maxLength: 20, fallback: "custom")
        let trimmedSymbol = custom.symbolName.trimmingCharacters(in: .whitespacesAndNewlines)

        self.init(
            id: custom.id.uuidString,
            slug: derivedSlug,
            name: trimmedName.isEmpty ? trimmedCommand : trimmedName,
            command: trimmedCommand,
            defaultArgs: custom.defaultArgs,
            symbolName: trimmedSymbol.isEmpty ? "terminal" : trimmedSymbol,
            colorToken: "slate",
            isBuiltIn: false,
            builtIn: nil
        )
    }

    /// All built-in agent descriptors in canonical display order.
    public static var builtIns: [AIAgentDescriptor] {
        BuiltInAIAgent.allCases.map(AIAgentDescriptor.init(builtIn:))
    }
}

/// Lightweight metadata attached to a live terminal session launched for an AI agent.
public struct AIAgentLaunchContext: Codable, Sendable, Hashable {
    public var agent: AIAgentDescriptor
    public var sessionName: String
    public var workingDirectory: String
    public var hostID: UUID?

    public init(
        agent: AIAgentDescriptor,
        sessionName: String,
        workingDirectory: String,
        hostID: UUID? = nil
    ) {
        self.agent = agent
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
        self.hostID = hostID
    }
}
