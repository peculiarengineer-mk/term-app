import SwiftUI
import UniformTypeIdentifiers
import Store

struct KeyImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var passphrase = ""
    @State private var savePassphrase = false
    @State private var sync = false
    @State private var showPicker = false
    @State private var error: String?

    private var parsed: ParsedKey? { try? KeyImporter.inspect(text) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Private key") {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Choose file…", systemImage: "folder") { showPicker = true }
                }
                if let p = parsed {
                    Text("Detected: \(p.type.rawValue)\(p.isEncrypted ? ", passphrase-protected" : "")")
                        .font(.footnote).foregroundStyle(.secondary)
                    if p.isEncrypted {
                        SecureField("Passphrase", text: $passphrase)
                        Toggle("Save passphrase in Keychain", isOn: $savePassphrase)
                    }
                }
                Toggle("Sync via iCloud Keychain", isOn: $sync)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            try KeyImporter.importKey(name: name, text: text, passphrase: passphrase.isEmpty ? nil : passphrase,
                                                      savePassphrase: savePassphrase, syncsViaICloud: sync)
                            dismiss()
                        } catch { self.error = "\(error)" }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || parsed == nil)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data, .text]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do { text = try String(contentsOf: url, encoding: .utf8) } catch { self.error = "\(error)" }
                case .failure(let e): error = "\(e)"
                }
            }
        }
    }
}
