import SwiftUI
import UIKit
import Store

struct KeyListView: View {
    @State private var keys: [StoredKey] = []
    @State private var error: String?
    @State private var showGenerate = false
    @State private var showImport = false
    @State private var confirmOff: StoredKey?
    private let store = KeyStore()

    var body: some View {
        List {
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(key.name).font(.headline)
                        Spacer()
                        Text(key.type.rawValue).font(.caption).foregroundStyle(.secondary)
                        if key.isEncrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    }
                    if !key.publicKey.isEmpty {
                        Button("Copy public key", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = key.publicKey
                        }
                        .buttonStyle(.borderless).font(.footnote)
                    }
                    Toggle("Sync via iCloud Keychain", isOn: Binding(
                        get: { key.syncsViaICloud },
                        set: { on in if on { setSync(true, key) } else { confirmOff = key } }))
                        .font(.footnote)
                }
            }
            .onDelete { idx in
                for i in idx { do { try store.delete(keys[i]) } catch { self.error = "\(error)" } }
                reload()
            }
        }
        .overlay { if keys.isEmpty { ContentUnavailableView("No keys", systemImage: "key") } }
        .navigationTitle("Keys")
        .toolbar {
            Menu("Add", systemImage: "plus") {
                Button("Generate Ed25519") { showGenerate = true }
                Button("Import") { showImport = true }
            }
        }
        .sheet(isPresented: $showGenerate, onDismiss: reload) { KeyGenerateView() }
        .sheet(isPresented: $showImport, onDismiss: reload) { KeyImportView() }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Turn off iCloud sync?",
                            isPresented: Binding(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                            titleVisibility: .visible, presenting: confirmOff) { key in
            Button("Turn Off Sync", role: .destructive) { setSync(false, key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the key from your other devices. It stays on this one.")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        do { keys = try store.list() } catch { self.error = "\(error)" }
    }

    private func setSync(_ on: Bool, _ key: StoredKey) {
        do { try store.setSynchronizable(on, for: key) } catch { self.error = "\(error)" }
        reload()
    }
}
