import Store
import SwiftUI
import WidgetKit

struct ActiveAgentsEntry: TimelineEntry {
    let date: Date
    let agents: [WidgetAgentSnapshot]
}

struct ActiveAgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActiveAgentsEntry {
        ActiveAgentsEntry(date: .now, agents: Self.sampleAgents)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActiveAgentsEntry) -> Void) {
        let agents = WidgetSnapshotStore.loadAgents()
        let resolved = context.isPreview && agents.isEmpty ? Self.sampleAgents : agents
        completion(ActiveAgentsEntry(date: .now, agents: resolved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActiveAgentsEntry>) -> Void) {
        let entry = ActiveAgentsEntry(date: .now, agents: WidgetSnapshotStore.loadAgents())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private static let sampleAgents: [WidgetAgentSnapshot] = [
        WidgetAgentSnapshot(
            sessionID: UUID(),
            hostID: UUID(),
            hostLabel: "Mac Studio",
            sessionName: "termapp-ai-claude-term-app",
            agentSlug: "claude",
            agentName: "Claude Code",
            projectSlug: "term-app",
            status: .approval,
            promptSnippet: "Run swift test? [y/N]"
        ),
        WidgetAgentSnapshot(
            sessionID: UUID(),
            hostID: UUID(),
            hostLabel: "Prod Bastion",
            sessionName: "termapp-ai-codex-api",
            agentSlug: "codex",
            agentName: "Codex",
            projectSlug: "api",
            status: .running
        ),
        WidgetAgentSnapshot(
            sessionID: nil,
            hostID: UUID(),
            hostLabel: "Dev Box",
            sessionName: "termapp-ai-agy-web",
            agentSlug: "agy",
            agentName: "Antigravity",
            projectSlug: "web",
            status: .idle
        ),
    ]
}

/// Home Screen and Lock Screen widget surfacing live and resumable remote AI agent sessions.
struct ActiveAgentsWidget: Widget {
    static let kind = "ActiveAgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ActiveAgentsProvider()) { entry in
            ActiveAgentsWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Agents")
        .description("Monitor running, approval-waiting, and resumable AI agent tmux sessions.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct ActiveAgentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ActiveAgentsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
                .containerBackground(WidgetPalette.background, for: .widget)
        case .systemMedium:
            mediumView
                .containerBackground(WidgetPalette.background, for: .widget)
        case .accessoryRectangular:
            accessoryRectangularView
                .containerBackground(.clear, for: .widget)
        default:
            smallView
                .containerBackground(WidgetPalette.background, for: .widget)
        }
    }

    @ViewBuilder
    private var smallView: some View {
        if let topAgent = entry.agents.first {
            let symbol = WidgetVisualStyle.agentSymbol(for: topAgent.agentSlug)
            let tint = WidgetVisualStyle.agentTint(for: topAgent.agentSlug)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WidgetSquircleIcon(symbolName: symbol, tint: tint, size: 30)
                    Spacer(minLength: 4)
                    WidgetStatusPill(rawStatus: topAgent.status.rawValue)
                }

                Spacer(minLength: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(topAgent.agentName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WidgetPalette.foreground)
                        .lineLimit(1)

                    Text(topAgent.projectSlug)
                        .font(.caption.monospaced())
                        .foregroundStyle(tint)
                        .lineLimit(1)

                    Text(topAgent.promptSnippet ?? topAgent.hostLabel)
                        .font(.caption2)
                        .foregroundStyle(topAgent.promptSnippet != nil ? WidgetPalette.amber : WidgetPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(deepLink(for: topAgent))
        } else {
            emptyStateView
                .widgetURL(TermAppDeepLink.openAgentsTab.url)
        }
    }

    @ViewBuilder
    private var mediumView: some View {
        if entry.agents.isEmpty {
            emptyStateView
                .widgetURL(TermAppDeepLink.openAgentsTab.url)
        } else {
            let approvalCount = entry.agents.count(where: { $0.status == .approval })
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetPalette.amber)
                    Text("AI Agents")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetPalette.foreground)
                    Spacer()
                    if approvalCount > 0 {
                        Text("\(approvalCount) waiting")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WidgetPalette.amber)
                    } else {
                        Text("\(entry.agents.count) active")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(WidgetPalette.secondary)
                    }
                }

                VStack(spacing: 6) {
                    ForEach(entry.agents.prefix(3)) { agent in
                        Link(destination: deepLink(for: agent)) {
                            agentCardRow(agent)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var accessoryRectangularView: some View {
        if let topAgent = entry.agents.first {
            let symbol = WidgetVisualStyle.agentSymbol(for: topAgent.agentSlug)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                    Text("\(topAgent.agentName) · \(topAgent.projectSlug)")
                        .font(.headline)
                        .lineLimit(1)
                }
                .widgetAccentable()

                Text("\(topAgent.status.displayTitle) · \(topAgent.hostLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let snippet = topAgent.promptSnippet {
                    Text(snippet)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(deepLink(for: topAgent))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("AI Agents", systemImage: "sparkles")
                    .font(.headline)
                Text("No active AI agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(TermAppDeepLink.openAgentsTab.url)
        }
    }

    private func agentCardRow(_ agent: WidgetAgentSnapshot) -> some View {
        let symbol = WidgetVisualStyle.agentSymbol(for: agent.agentSlug)
        let tint = WidgetVisualStyle.agentTint(for: agent.agentSlug)
        let statusColor = WidgetVisualStyle.statusColor(for: agent.status.rawValue)

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            WidgetSquircleIcon(symbolName: symbol, tint: tint, size: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(agent.agentName) · \(agent.projectSlug)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.foreground)
                    .lineLimit(1)

                Text(agent.promptSnippet ?? agent.hostLabel)
                    .font(.caption2)
                    .foregroundStyle(agent.promptSnippet != nil ? WidgetPalette.amber : WidgetPalette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            WidgetStatusPill(rawStatus: agent.status.rawValue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(WidgetPalette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    agent.status == .approval ? WidgetPalette.amber.opacity(0.42) : WidgetPalette.cardBorder,
                    lineWidth: 0.5
                )
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            WidgetSquircleIcon(symbolName: "sparkles", tint: WidgetPalette.amber, size: 32)
            Text("No active AI agents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetPalette.foreground)
                .multilineTextAlignment(.center)
            Text("Tap to launch in AmberTTY")
                .font(.caption2)
                .foregroundStyle(WidgetPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deepLink(for agent: WidgetAgentSnapshot) -> URL {
        if let sessionID = agent.sessionID {
            return TermAppDeepLink.focusSession(sessionID: sessionID).url
        }
        return TermAppDeepLink.launchAgent(
            hostID: agent.hostID,
            agentSlug: agent.agentSlug,
            sessionName: agent.sessionName
        ).url
    }
}
