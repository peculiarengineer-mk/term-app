import SwiftUI
import Store

/// Shown when a key-auth host's key is not in this device's Keychain.
struct KeyMissingView: View {
    let host: Host
    let onRetry: () -> Void
    @State private var showImport = false
    @State private var showGenerate = false
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Key not on this device").font(.headline)
            Text("This host uses a key that is not in this device's Keychain. It may not have synced, or it was deleted.")
                .font(.footnote).multilineTextAlignment(.center)
            Button("Import a Key") { showImport = true }
            Button("Generate a Key") { showGenerate = true }
            Button("Edit Host") { showEditor = true }
        }
        .padding()
        // A new key has a new id, so after importing or generating one the editor opens to pick it.
        .sheet(isPresented: $showImport, onDismiss: { showEditor = true }) { KeyImportView() }
        .sheet(isPresented: $showGenerate, onDismiss: { showEditor = true }) { KeyGenerateView() }
        .sheet(isPresented: $showEditor, onDismiss: onRetry) { NavigationStack { HostEditorView(host: host) } }
    }
}
