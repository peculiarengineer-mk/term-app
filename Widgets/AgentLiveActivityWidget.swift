import ActivityKit
import Store
import SwiftUI
import WidgetKit

/// Dynamic Island and Lock Screen Live Activity configuration for running AI agent sessions.
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            lockScreenBanner(context: context)
                .widgetURL(TermAppDeepLink.focusSession(sessionID: context.attributes.sessionID).url)
                .activityBackgroundTint(WidgetPalette.background)
                .activitySystemActionForegroundColor(WidgetPalette.foreground)
        } dynamicIsland: { context in
            let agentSymbol = WidgetVisualStyle.agentSymbol(for: context.attributes.agentSlug)
            let agentTint = WidgetVisualStyle.agentTint(for: context.attributes.agentSlug)
            let statusColor = WidgetVisualStyle.statusColor(for: context.state.status)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetSquircleIcon(symbolName: agentSymbol, tint: agentTint, size: 34)
                        .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    WidgetStatusPill(rawStatus: context.state.status)
                        .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(context.attributes.agentName) · \(context.attributes.projectName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WidgetPalette.foreground)
                            .lineLimit(1)

                        Text(context.attributes.hostLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(WidgetPalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottomView(context: context, statusColor: statusColor)
                }
            } compactLeading: {
                Image(systemName: agentSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(agentTint)
            } compactTrailing: {
                compactTrailingIcon(status: context.state.status, color: statusColor)
            } minimal: {
                Image(systemName: agentSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .widgetURL(TermAppDeepLink.focusSession(sessionID: context.attributes.sessionID).url)
            .keylineTint(agentTint)
        }
    }

    @ViewBuilder
    private func lockScreenBanner(context: ActivityViewContext<AgentActivityAttributes>) -> some View {
        let agentSymbol = WidgetVisualStyle.agentSymbol(for: context.attributes.agentSlug)
        let agentTint = WidgetVisualStyle.agentTint(for: context.attributes.agentSlug)
        let isApproval = context.state.status == WidgetAgentStatus.approval.rawValue

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WidgetSquircleIcon(symbolName: agentSymbol, tint: agentTint, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(context.attributes.agentName) · \(context.attributes.projectName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WidgetPalette.foreground)
                        .lineLimit(1)

                    Text(context.attributes.hostLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                WidgetStatusPill(rawStatus: context.state.status)
            }

            if isApproval {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetPalette.amber)
                    Text(context.state.statusMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(WidgetPalette.foreground)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(WidgetPalette.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WidgetPalette.amber.opacity(0.38), lineWidth: 0.75)
                )
            } else {
                HStack(spacing: 6) {
                    Text(context.state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(context.state.updatedAt, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WidgetPalette.secondary)
                }
            }
        }
        .padding(14)
        .background(WidgetPalette.background)
    }

    @ViewBuilder
    private func expandedBottomView(
        context: ActivityViewContext<AgentActivityAttributes>,
        statusColor: Color
    ) -> some View {
        let isApproval = context.state.status == WidgetAgentStatus.approval.rawValue

        if isApproval, !context.state.statusMessage.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.amber)
                Text(context.state.statusMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(WidgetPalette.foreground)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(WidgetPalette.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                Text("Tap to jump into terminal")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondary)
                Spacer()
                Text(context.state.updatedAt, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(WidgetPalette.secondary)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func compactTrailingIcon(status: String, color: Color) -> some View {
        switch WidgetAgentStatus(rawValue: status.lowercased()) {
        case .running:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.trailing, 2)
        case .approval:
            Image(systemName: "bell.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        case .idle, nil:
            Image(systemName: "circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
