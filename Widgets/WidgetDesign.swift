import Store
import SwiftUI
import WidgetKit

/// Apple Pro Dark color tokens and shared visual primitives for `TermAppWidgets`.
enum WidgetPalette {
    static let background = Color(red: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0)
    static let cardFill = Color.white.opacity(0.07)
    static let cardBorder = Color.white.opacity(0.13)
    static let foreground = Color(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0)
    static let secondary = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)

    static let amber = Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
    static let cyan = Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
    static let green = Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
    static let blue = Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
    static let purple = Color(red: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0)
    static let red = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
}

/// Resolves SF Symbols and semantic tints for AI coding agents and environments inside widgets & Live Activities.
enum WidgetVisualStyle {
    static func agentSymbol(for slug: String) -> String {
        let normalized = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let builtIn = BuiltInAIAgent(rawValue: normalized) {
            return builtIn.symbolName
        }
        return "terminal"
    }

    static func agentTint(for slug: String) -> Color {
        let normalized = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch BuiltInAIAgent(rawValue: normalized) {
        case .claude: return WidgetPalette.amber
        case .agy: return WidgetPalette.cyan
        case .codex: return WidgetPalette.green
        case .aider: return WidgetPalette.blue
        case .opencode: return WidgetPalette.purple
        case nil: return WidgetPalette.secondary
        }
    }

    static func statusColor(for rawStatus: String) -> Color {
        switch WidgetAgentStatus(rawValue: rawStatus.lowercased()) {
        case .running: WidgetPalette.cyan
        case .approval: WidgetPalette.amber
        case .done: WidgetPalette.green
        case .idle, nil: WidgetPalette.secondary
        }
    }

    static func statusTitle(for rawStatus: String) -> String {
        WidgetAgentStatus(rawValue: rawStatus.lowercased())?.displayTitle ?? "Idle"
    }

    static func statusSymbol(for rawStatus: String) -> String {
        switch WidgetAgentStatus(rawValue: rawStatus.lowercased()) {
        case .running: "circle.fill"
        case .approval: "bell.fill"
        case .done: "checkmark.circle.fill"
        case .idle, nil: "pause.circle.fill"
        }
    }

    static func hostAppearance(for host: WidgetHostSnapshot) -> (symbol: String, tint: Color) {
        let lowerHost = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combinedTokens = Set(
            (host.tags + [host.label, host.hostname])
                .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        )

        if !combinedTokens.isDisjoint(with: ["prod", "production", "api", "live", "web"]) {
            return ("server.rack", WidgetPalette.red)
        }
        if lowerHost.hasSuffix(".local") || lowerHost.hasSuffix(".ts.net")
            || !combinedTokens.isDisjoint(with: ["homelab", "home", "local", "lan", "mac", "nas", "pi"]) {
            return ("desktopcomputer", WidgetPalette.cyan)
        }
        if !combinedTokens.isDisjoint(with: ["db", "sql", "postgres", "postgresql", "mysql", "redis", "mongo", "mongodb", "staging", "stage"]) {
            return ("cylinder.split.1x2.fill", WidgetPalette.purple)
        }
        return ("cloud.fill", WidgetPalette.secondary)
    }

    static func endpointSubtitle(for host: WidgetHostSnapshot) -> String {
        let userPart = host.username.isEmpty ? "" : "\(host.username)@"
        return "\(userPart)\(host.hostname)"
    }
}

/// Frosted continuous-corner squircle icon matching AmberTTY's `ProSquircleIcon`.
struct WidgetSquircleIcon: View {
    let symbolName: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        let cornerRadius = size * (10.0 / 36.0)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.20))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [tint.opacity(0.48), tint.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            Image(systemName: symbolName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact capsule badge displaying live AI agent status inside widgets and Live Activities.
struct WidgetStatusPill: View {
    let rawStatus: String

    private var color: Color { WidgetVisualStyle.statusColor(for: rawStatus) }
    private var title: String { WidgetVisualStyle.statusTitle(for: rawStatus) }
    private var symbol: String { WidgetVisualStyle.statusSymbol(for: rawStatus) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: rawStatus == WidgetAgentStatus.running.rawValue ? 6 : 9, weight: .bold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.40), lineWidth: 0.5))
    }
}
