import SwiftUI
import Store

struct KeyGenerateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var sync = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Comment (optional)", text: $comment)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Sync via iCloud Keychain", isOn: $sync)
                Text("Generates an Ed25519 key.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Generate Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        do {
                            try KeyGenerator.generateAndStore(name: name, comment: comment, syncsViaICloud: sync)
                            dismiss()
                        } catch { self.error = "\(error)" }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
