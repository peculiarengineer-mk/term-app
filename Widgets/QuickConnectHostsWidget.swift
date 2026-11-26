import Store
import SwiftUI
import WidgetKit

struct QuickConnectHostsEntry: TimelineEntry {
    let date: Date
    let hosts: [WidgetHostSnapshot]
}

struct QuickConnectHostsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectHostsEntry {
        QuickConnectHostsEntry(date: .now, hosts: Self.sampleHosts)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectHostsEntry) -> Void) {
        let hosts = WidgetSnapshotStore.loadHosts()
        let resolved = context.isPreview && hosts.isEmpty ? Self.sampleHosts : hosts
        completion(QuickConnectHostsEntry(date: .now, hosts: resolved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectHostsEntry>) -> Void) {
        let entry = QuickConnectHostsEntry(date: .now, hosts: WidgetSnapshotStore.loadHosts())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private static let sampleHosts: [WidgetHostSnapshot] = [
        WidgetHostSnapshot(
            id: UUID(),
            label: "Prod Bastion",
            hostname: "bastion.prod.internal",
            username: "deploy",
            tags: ["prod"],
            lastConnectedAt: .now
        ),
        WidgetHostSnapshot(
            id: UUID(),
            label: "Mac Studio",
            hostname: "studio.local",
            username: "keith",
            tags: ["homelab"],
            lastConnectedAt: .now.addingTimeInterval(-3600)
        ),
        WidgetHostSnapshot(
            id: UUID(),
            label: "Staging DB",
            hostname: "10.0.4.12",
            username: "postgres",
            tags: ["db"]
        ),
    ]
}

/// Home Screen and Lock Screen widget for 1-tap SSH connection to saved hosts.
struct QuickConnectHostsWidget: Widget {
    static let kind = "QuickConnectHostsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickConnectHostsProvider()) { entry in
            QuickConnectHostsWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Connect")
        .description("Launch an SSH terminal session on your saved hosts in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct QuickConnectHostsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickConnectHostsEntry

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
        if let topHost = entry.hosts.first {
            let appearance = WidgetVisualStyle.hostAppearance(for: topHost)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WidgetSquircleIcon(symbolName: appearance.symbol, tint: appearance.tint, size: 32)
                    Spacer()
                    if entry.hosts.count > 1 {
                        Text("+\(entry.hosts.count - 1)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(WidgetPalette.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WidgetPalette.cardFill, in: Capsule())
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(topHost.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WidgetPalette.foreground)
                        .lineLimit(1)

                    Text(WidgetVisualStyle.endpointSubtitle(for: topHost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Connect")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(WidgetPalette.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WidgetPalette.amber.opacity(0.18), in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(TermAppDeepLink.connectHost(hostID: topHost.id).url)
        } else {
            emptyStateView
        }
    }

    @ViewBuilder
    private var mediumView: some View {
        if entry.hosts.isEmpty {
            emptyStateView
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetPalette.amber)
                    Text("Quick Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetPalette.foreground)
                    Spacer()
                    Text("\(entry.hosts.count) \(entry.hosts.count == 1 ? "host" : "hosts")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WidgetPalette.secondary)
                }

                VStack(spacing: 6) {
                    ForEach(entry.hosts.prefix(3)) { host in
                        Link(destination: TermAppDeepLink.connectHost(hostID: host.id).url) {
                            hostCardRow(host)
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
        if let topHost = entry.hosts.first {
            let appearance = WidgetVisualStyle.hostAppearance(for: topHost)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: appearance.symbol)
                        .font(.caption.weight(.semibold))
                    Text(topHost.displayName)
                        .font(.headline)
                        .lineLimit(1)
                }
                .widgetAccentable()

                Text(WidgetVisualStyle.endpointSubtitle(for: topHost))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Tap to SSH")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(TermAppDeepLink.connectHost(hostID: topHost.id).url)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("TermApp", systemImage: "terminal.fill")
                    .font(.headline)
                Text("Add hosts in TermApp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hostCardRow(_ host: WidgetHostSnapshot) -> some View {
        let appearance = WidgetVisualStyle.hostAppearance(for: host)
        return HStack(spacing: 8) {
            WidgetSquircleIcon(symbolName: appearance.symbol, tint: appearance.tint, size: 24)

            Text(host.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetPalette.foreground)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(WidgetVisualStyle.endpointSubtitle(for: host))
                .font(.caption2.monospaced())
                .foregroundStyle(WidgetPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "arrow.up.right.circle.fill")
                .font(.caption)
                .foregroundStyle(WidgetPalette.amber)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(WidgetPalette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WidgetPalette.cardBorder, lineWidth: 0.5)
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            WidgetSquircleIcon(symbolName: "server.rack", tint: WidgetPalette.amber, size: 32)
            Text("Add hosts in TermApp")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetPalette.foreground)
                .multilineTextAlignment(.center)
            Text("Saved SSH servers appear here.")
                .font(.caption2)
                .foregroundStyle(WidgetPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
