import SwiftUI
import SwiftData
import Store
import TermUI

/// Observable two-pane split state for a `SessionTabsView` window on regular-width layouts.
@MainActor @Observable
final class SplitPaneState {
    enum SplitAxis: String, Sendable {
        case horizontal
        case vertical
    }

    enum SplitFocus: Sendable {
        case primary
        case secondary
    }

    static let minRatio: CGFloat = 0.25
    static let maxRatio: CGFloat = 0.75
    static let defaultRatio: CGFloat = 0.5

    var secondarySessionID: UUID?
    var axis: SplitAxis = .horizontal
    var ratio: CGFloat = SplitPaneState.defaultRatio {
        didSet {
            let clamped = Self.clampRatio(ratio)
            if ratio != clamped {
                ratio = clamped
            }
        }
    }
    var focusedPane: SplitFocus = .primary

    var isSplit: Bool {
        secondarySessionID != nil
    }

    static func clampRatio(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultRatio }
        return min(max(value, minRatio), maxRatio)
    }

    /// Opens or updates the secondary split pane with `sessionID` along `axis`.
    func split(with sessionID: UUID, axis: SplitAxis) {
        let wasSplit = secondarySessionID != nil
        self.axis = axis
        self.secondarySessionID = sessionID
        if !wasSplit {
            self.ratio = Self.defaultRatio
        }
        self.focusedPane = .secondary
    }

    /// Swaps primary and secondary session IDs while keeping focus on the same logical session.
    func swap(primary: inout UUID?) {
        guard let currentPrimary = primary,
              let currentSecondary = secondarySessionID,
              currentPrimary != currentSecondary else {
            return
        }
        primary = currentSecondary
        secondarySessionID = currentPrimary
        focusedPane = (focusedPane == .primary) ? .secondary : .primary
    }

    /// Collapses back to single-pane mode and returns focus to primary.
    func closeSplit() {
        secondarySessionID = nil
        focusedPane = .primary
    }

    /// Toggles focus between primary and secondary panes when split.
    func toggleFocus() {
        guard secondarySessionID != nil else {
            focusedPane = .primary
            return
        }
        focusedPane = (focusedPane == .primary) ? .secondary : .primary
    }

    /// Switches between side-by-side (`.horizontal`) and top/bottom (`.vertical`) layouts.
    func toggleAxis() {
        axis = (axis == .horizontal) ? .vertical : .horizontal
    }

    /// Automatically collapses split mode if either pane is missing, closed, or points to the same session.
    func reconcile(primaryID: UUID?, validIDs: Set<UUID>) {
        guard let primaryID,
              validIDs.contains(primaryID),
              let secondarySessionID,
              validIDs.contains(secondarySessionID),
              secondarySessionID != primaryID else {
            if self.secondarySessionID != nil || focusedPane != .primary {
                closeSplit()
            }
            return
        }
    }
}

/// Reusable 8pt draggable split divider with a centered 1pt hairline and 24×3pt pill grabber handle.
struct DraggableSplitDivider: View {
    static let thickness: CGFloat = 8

    let axis: SplitPaneState.SplitAxis
    @Binding var ratio: CGFloat
    let totalLength: CGFloat
    let theme: TerminalTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStartRatio: CGFloat?

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var isDragging: Bool {
        dragStartRatio != nil
    }

    var body: some View {
        ZStack {
            Color.clear

            if axis == .horizontal {
                Rectangle()
                    .fill(isDragging ? theme.accentColor.opacity(0.6) : palette.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                Capsule()
                    .fill(isDragging ? theme.accentColor : theme.secondaryForegroundColor.opacity(0.55))
                    .frame(width: 3, height: 24)
            } else {
                Rectangle()
                    .fill(isDragging ? theme.accentColor.opacity(0.6) : palette.hairline)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(isDragging ? theme.accentColor : theme.secondaryForegroundColor.opacity(0.55))
                    .frame(width: 24, height: 3)
            }
        }
        .frame(
            width: axis == .horizontal ? Self.thickness : nil,
            height: axis == .vertical ? Self.thickness : nil
        )
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartRatio == nil {
                        dragStartRatio = ratio
                        AppHaptics.impact(.light)
                    }
                    let startRatio = dragStartRatio ?? ratio
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    let available = max(1, totalLength - Self.thickness)
                    ratio = SplitPaneState.clampRatio(startRatio + (delta / available))
                }
                .onEnded { _ in
                    dragStartRatio = nil
                }
        )
        .onTapGesture(count: 2) {
            AppHaptics.impact(.light)
            if reduceMotion {
                ratio = SplitPaneState.defaultRatio
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    ratio = SplitPaneState.defaultRatio
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Split pane divider")
        .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                ratio = SplitPaneState.clampRatio(ratio + 0.05)
            case .decrement:
                ratio = SplitPaneState.clampRatio(ratio - 0.05)
            @unknown default:
                break
            }
        }
    }
}

/// Compact picker sheet listing open sessions and saved hosts to launch directly into the secondary split pane.
struct SplitPanePickerSheet: View {
    let axis: SplitPaneState.SplitAxis
    let primarySessionID: UUID?
    let currentWindowID: UUID
    let theme: TerminalTheme
    let onSelectSession: (UUID) -> Void
    let onConnectHost: (Host) -> Void

    @Environment(SessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Host.label) private var hosts: [Host]
    @State private var search = ""

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var openSessions: [LiveSession] {
        manager.sessions.filter { live in
            guard live.id != primarySessionID else { return false }
            guard !query.isEmpty else { return true }
            return live.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredHosts: [Host] {
        hosts.filter { host in
            guard !query.isEmpty else { return true }
            return host.label.localizedCaseInsensitiveContains(query)
                || host.hostname.localizedCaseInsensitiveContains(query)
                || host.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !openSessions.isEmpty {
                    Section("Open Sessions") {
                        ForEach(openSessions) { live in
                            Button {
                                AppHaptics.impact(.light)
                                onSelectSession(live.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ConnectionStatusDot(
                                        status: live.connectionStatus,
                                        size: 8,
                                        glow: live.connectionStatus == .connected
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(live.title)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            AgentActivityBadge(state: live.agentActivityState)
                                        }
                                        Text(sessionSubtitle(for: live))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2")
                                        .font(.subheadline)
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !filteredHosts.isEmpty {
                    Section("Saved Hosts") {
                        ForEach(filteredHosts) { host in
                            Button {
                                AppHaptics.impact(.light)
                                onConnectHost(host)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    HostEnvironmentIcon(host: host)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.label.isEmpty ? host.hostname : host.label)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(hostAddressSubtitle(for: host))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .font(.title3)
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if openSessions.isEmpty && filteredHosts.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Sessions or Hosts" : "No Matching Sessions or Hosts",
                        systemImage: axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2",
                        description: Text(query.isEmpty
                            ? "Add a host in the Hosts tab to open it in a split pane."
                            : "Try clearing your search filter.")
                    )
                }
            }
            .searchable(text: $search, prompt: "Filter sessions or hosts")
            .navigationTitle("Pick Session or Host for Split Pane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sessionSubtitle(for live: LiveSession) -> String {
        if let windowID = live.windowID, windowID != currentWindowID {
            return "\(live.connectionStatus.accessibilityLabel) · In another window"
        }
        return live.connectionStatus.accessibilityLabel
    }

    private func hostAddressSubtitle(for host: Host) -> String {
        let userPart = host.username.isEmpty ? "" : "\(host.username)@"
        let portPart = host.port == 22 ? "" : ":\(host.port)"
        return "\(userPart)\(host.hostname)\(portPart)"
    }
}
