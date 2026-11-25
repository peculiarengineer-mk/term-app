import SwiftUI

/// Sheet listing every live session across windows.
struct SessionSwitcher: View {
    var selectedID: UUID? = nil
    let onSelect: (UUID) -> Void
    let onOpenInWindow: (UUID) -> Void
    @Environment(SessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.sessions) { live in
                    let isSelected = live.id == selectedID
                    HStack(spacing: 10) {
                        Button {
                            AppHaptics.impact(.light)
                            onSelect(live.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                ConnectionStatusDot(status: live.connectionStatus, size: 8, glow: live.connectionStatus == .connected)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(live.title)
                                            .font(.body.weight(isSelected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                        AgentActivityBadge(state: live.agentActivityState)
                                    }
                                    Text(live.connectionStatus.accessibilityLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(live.title)
                        .accessibilityValue(live.connectionStatus.accessibilityLabel)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])

                        Button {
                            AppHaptics.impact(.light)
                            onOpenInWindow(live.id)
                            dismiss()
                        } label: {
                            Label("New window", systemImage: "macwindow.badge.plus")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 40, minHeight: 40)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.borderless)
                    .swipeActions { Button("Close", role: .destructive) { manager.close(live.id) } }
                }
            }
            .overlay {
                if manager.sessions.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "terminal")
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
