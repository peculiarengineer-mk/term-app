import SwiftUI
import UIKit

/// Sheet listing every live session across windows.
struct SessionSwitcher: View {
    var selectedID: UUID? = nil
    let onSelect: (UUID) -> Void
    let onOpenInWindow: (UUID) -> Void
    @Environment(SessionManager.self) private var manager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var closingSession: LiveSession?

    private var canOpenInNewWindow: Bool {
        UIApplication.shared.supportsMultipleScenes && horizontalSizeClass == .regular
    }

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

                        if canOpenInNewWindow {
                            Button {
                                AppHaptics.impact(.light)
                                onOpenInWindow(live.id)
                                dismiss()
                            } label: {
                                Label("New window", systemImage: "macwindow.badge.plus")
                                    .labelStyle(.iconOnly)
                                    .minTapTarget()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Close", role: .destructive) {
                            requestClose(live)
                        }
                    }
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
            .confirmationDialog(
                "Close active session?",
                isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } }),
                titleVisibility: .visible,
                presenting: closingSession
            ) { live in
                if live.ephemeralHost != nil {
                    Button("Save Host", systemImage: "bookmark.badge.plus") {
                        manager.saveEphemeralHost(for: live.id, in: modelContext)
                    }
                }
                Button("Close Session", role: .destructive) {
                    AppHaptics.impact(.light)
                    closingSession = nil
                    manager.close(live.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { live in
                Text("Closing \"\(live.title)\" will disconnect the active SSH session.")
            }
        }
    }

    private func requestClose(_ live: LiveSession) {
        if live.connectionStatus == .connected {
            AppHaptics.impact(.light)
            closingSession = live
        } else {
            AppHaptics.impact(.light)
            manager.close(live.id)
        }
    }
}
