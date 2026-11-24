import SwiftUI
import SwiftData
import UIKit
import Store
import TermUI

struct KeyListView: View {
    @Environment(ProStore.self) private var proStore
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var hosts: [Host]
    @State private var keys: [StoredKey] = []
    @State private var keysWithSavedPassphrase: Set<UUID> = []
    @State private var copiedKeyID: UUID?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showGenerate = false
    @State private var showImport = false
    @State private var confirmOff: StoredKey?
    @State private var confirmDelete: StoredKey?
    @State private var confirmClearPassphrase: StoredKey?
    @State private var pushingKeyID: UUID?
    @State private var pushSuccessMessage: String?
    @State private var showingPaywall = false
    private let store = KeyStore()
    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        keysList
            .sheet(isPresented: $showGenerate, onDismiss: reload) {
                KeyGenerateView()
            }
            .sheet(isPresented: $showImport, onDismiss: reload) {
                KeyImportView()
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView()
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(theme.accentColor)
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
            .alert(
                "Pushed to DigitalOcean",
                isPresented: Binding(get: { pushSuccessMessage != nil }, set: { if !$0 { pushSuccessMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(pushSuccessMessage ?? "")
            }
            .confirmationDialog(
                "Turn off iCloud sync?",
                isPresented: Binding(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                titleVisibility: .visible,
                presenting: confirmOff
            ) { key in
                Button("Turn Off Sync", role: .destructive) { setSync(false, key) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the key from your other devices. It stays on this one.")
            }
            .confirmationDialog(
                confirmDeleteTitle,
                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible,
                presenting: confirmDelete
            ) { key in
                Button("Delete Key", role: .destructive) { deleteKey(key) }
                Button("Cancel", role: .cancel) {}
            } message: { key in
                Text(deleteWarningMessage(for: key))
            }
            .confirmationDialog(
                "Clear saved passphrase?",
                isPresented: Binding(get: { confirmClearPassphrase != nil }, set: { if !$0 { confirmClearPassphrase = nil } }),
                titleVisibility: .visible,
                presenting: confirmClearPassphrase
            ) { key in
                Button("Clear Passphrase", role: .destructive) { clearPassphrase(for: key) }
                Button("Cancel", role: .cancel) {}
            } message: { key in
                Text("You will be asked for the passphrase the next time you connect using \"\(key.name)\".")
            }
            .onAppear {
                authState.refresh()
                reload()
            }
            .onDisappear {
                copyResetTask?.cancel()
                copyResetTask = nil
            }
    }

    private var keysList: some View {
        List {
            ForEach(keys) { key in
                keyListRow(for: key)
            }
        }
        .overlay {
            if keys.isEmpty {
                ContentUnavailableView {
                    Label("No SSH keys", systemImage: "key.fill")
                } description: {
                    Text("Generate a Secure Enclave or Ed25519 key on this device, or import an existing OpenSSH private key.")
                } actions: {
                    Button("Generate Key") { showGenerate = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import Key") { showImport = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("Generate Key", systemImage: "plus.circle") { showGenerate = true }
                    Button("Import Key", systemImage: "square.and.arrow.down") { showImport = true }
                }
            }
        }
    }

    private func keyListRow(for key: StoredKey) -> some View {
        keyRow(for: key)
            .contextMenu {
                if !key.publicKey.isEmpty {
                    Button("Copy public key", systemImage: "doc.on.doc") {
                        copyPublicKey(for: key)
                    }
                    ShareLink(item: key.publicKey) {
                        Label("Share public key", systemImage: "square.and.arrow.up")
                    }
                    if authState.hasDigitalOceanToken {
                        Button("Push to DigitalOcean", systemImage: "icloud.and.arrow.up") {
                            pushKeyToDigitalOcean(key)
                        }
                        .disabled(pushingKeyID != nil)
                    }
                }
                if keysWithSavedPassphrase.contains(key.id) {
                    Button("Clear saved passphrase", systemImage: "key.slash", role: .destructive) {
                        confirmClearPassphrase = key
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmDelete = key
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    confirmDelete = key
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if keysWithSavedPassphrase.contains(key.id) {
                    Button {
                        confirmClearPassphrase = key
                    } label: {
                        Label("Clear Passphrase", systemImage: "key.slash")
                    }
                    .tint(.orange)
                }
            }
    }

    private var confirmDeleteTitle: String {
        guard let key = confirmDelete else { return "Delete key?" }
        return "Delete \"\(key.name)\"?"
    }

    private func keyRow(for key: StoredKey) -> some View {
        let isCopied = copiedKeyID == key.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(key.name)
                    .font(.headline)

                Spacer()

                Text(key.type == .secureEnclaveP256 ? "Secure Enclave P-256" : key.type.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if key.isEncrypted {
                    Image(systemName: "lock.rectangle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Passphrase-protected")
                }

                if pushingKeyID == key.id {
                    ProgressView()
                        .controlSize(.small)
                }

                Menu {
                    if !key.publicKey.isEmpty {
                        Button("Copy public key", systemImage: "doc.on.doc") {
                            copyPublicKey(for: key)
                        }
                        ShareLink(item: key.publicKey) {
                            Label("Share public key", systemImage: "square.and.arrow.up")
                        }
                        if authState.hasDigitalOceanToken {
                            Button("Push to DigitalOcean", systemImage: "icloud.and.arrow.up") {
                                pushKeyToDigitalOcean(key)
                            }
                            .disabled(pushingKeyID != nil)
                        }
                    }
                    if keysWithSavedPassphrase.contains(key.id) {
                        Button("Clear saved passphrase", systemImage: "key.slash", role: .destructive) {
                            confirmClearPassphrase = key
                        }
                    }
                    Divider()
                    Button("Delete Key", systemImage: "trash", role: .destructive) {
                        confirmDelete = key
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions for \(key.name)")
            }

            if !key.publicKey.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        copyPublicKey(for: key)
                    } label: {
                        Label(
                            isCopied ? "Copied" : "Copy public key",
                            systemImage: isCopied ? "checkmark" : "doc.on.doc"
                        )
                        .foregroundStyle(isCopied ? Color.green : Color.accentColor)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: key.publicKey) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.footnote)
            }

            if key.type == .secureEnclaveP256 {
                Label("This device only", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Sync via iCloud Keychain", isOn: Binding(
                    get: { key.syncsViaICloud },
                    set: { on in if on { setSync(true, key) } else { confirmOff = key } }
                ))
                .font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }

    private func deleteWarningMessage(for key: StoredKey) -> String {
        var parts: [String] = []
        if key.type == .secureEnclaveP256 {
            parts.append("This Secure Enclave key cannot be recovered once deleted.")
        } else {
            parts.append("This removes \"\(key.name)\" from Keychain.")
        }
        let referencingCount = hosts.count(where: { $0.keyID == key.id })
        if referencingCount > 0 {
            let noun = referencingCount == 1 ? "saved host uses" : "saved hosts use"
            parts.append("\(referencingCount) \(noun) this key.")
        }
        return parts.joined(separator: " ")
    }

    private func copyPublicKey(for key: StoredKey) {
        UIPasteboard.general.string = key.publicKey
        AppHaptics.notify(.success)
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedKeyID = key.id
        }
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if copiedKeyID == key.id {
                    copiedKeyID = nil
                }
            }
        }
    }

    private func deleteKey(_ key: StoredKey) {
        do {
            try store.delete(key)
            AppHaptics.notify(.warning)
            reload()
        } catch {
            self.error = "\(error)"
        }
    }

    private func reload() {
        do {
            let loaded = try store.list()
            keys = loaded
            keysWithSavedPassphrase = Set(loaded.filter { ((try? store.passphrase(for: $0)) ?? nil) != nil }.map(\.id))
        } catch {
            self.error = "\(error)"
        }
    }

    private func clearPassphrase(for key: StoredKey) {
        do {
            try KeychainStore().delete(service: KeyStore.passphraseService, account: key.id.uuidString)
            AppHaptics.notify(.warning)
            reload()
        } catch {
            self.error = "\(error)"
        }
    }

    private func setSync(_ on: Bool, _ key: StoredKey) {
        do {
            try store.setSynchronizable(on, for: key)
        } catch {
            self.error = "\(error)"
        }
        reload()
    }

    private func pushKeyToDigitalOcean(_ key: StoredKey) {
        guard proStore.isProUnlocked else {
            AppHaptics.impact(.light)
            showingPaywall = true
            return
        }
        guard !key.publicKey.isEmpty else { return }
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            self.error = DOError.missingToken.localizedDescription
            return
        }

        AppHaptics.impact(.light)
        pushingKeyID = key.id
        Task {
            defer { pushingKeyID = nil }
            do {
                let pushed = try await DigitalOceanClient(token: token).createSSHKey(
                    name: key.name,
                    publicKey: key.publicKey
                )
                AppHaptics.notify(.success)
                pushSuccessMessage = "\"\(pushed.name)\" is now registered on your DigitalOcean account."
            } catch {
                AppHaptics.notify(.error)
                self.error = error.localizedDescription
            }
        }
    }
}
