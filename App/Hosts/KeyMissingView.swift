import SwiftUI
import SwiftData
import Store
import TermUI

/// Shown when a key-auth host's key is not in this device's Keychain.
struct KeyMissingView: View {
    let host: Host
    var keyName: String? = nil
    let onRetry: () -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var showImport = false
    @State private var showGenerate = false
    @State private var showEditor = false
    @State private var pendingRetry = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var descriptionText: String {
        if let keyName, !keyName.isEmpty {
            return "The key \"\(keyName)\" is not in this device's Keychain. It may not have synced, or it was deleted."
        }
        return "This host uses a key that is not in this device's Keychain. It may not have synced, or it was deleted."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    Text("Key not on this device")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button {
                        AppHaptics.impact(.light)
                        showImport = true
                    } label: {
                        Label("Import a Key", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        AppHaptics.impact(.light)
                        showGenerate = true
                    } label: {
                        Label("Generate a Key", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        AppHaptics.impact(.light)
                        showEditor = true
                    } label: {
                        Label("Edit Host", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if let onClose {
                        Button(role: .destructive) {
                            AppHaptics.impact(.light)
                            onClose()
                        } label: {
                            Text("Close Tab")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: 380)
            .padding(24)
            .background(
                theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .sheet(isPresented: $showImport, onDismiss: retryIfCreated) {
            KeyImportView(onCreatedKey: { newKey in
                assignKey(newKey)
            })
        }
        .sheet(isPresented: $showGenerate, onDismiss: retryIfCreated) {
            KeyGenerateView(onCreatedKey: { newKey in
                assignKey(newKey)
            })
        }
        .sheet(isPresented: $showEditor, onDismiss: onRetry) {
            NavigationStack {
                HostEditorView(host: host)
            }
        }
    }

    private func assignKey(_ newKey: StoredKey) {
        host.keyID = newKey.id
        host.authMethod = "key"
        host.touch()
        try? context.save()
        pendingRetry = true
    }

    private func retryIfCreated() {
        guard pendingRetry else { return }
        pendingRetry = false
        onRetry()
    }
}
