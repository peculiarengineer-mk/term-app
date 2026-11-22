import SwiftUI

/// Sheet listing every live session across windows.
struct SessionSwitcher: View {
    let onSelect: (UUID) -> Void
    let onOpenInWindow: (UUID) -> Void
    @Environment(SessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.sessions) { live in
                    HStack {
                        Button(live.title) { onSelect(live.id); dismiss() }
                        Spacer()
                        Button { onOpenInWindow(live.id); dismiss() } label: {
                            Label("New window", systemImage: "macwindow.badge.plus")
                                .labelStyle(.iconOnly)
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
