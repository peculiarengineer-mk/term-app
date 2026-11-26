import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Store

struct KeyImportView: View {
    private static let maxKeyFileBytes = 1024 * 1024

    let onCreated: (() -> Void)?
    let onCreatedKey: ((StoredKey) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var inspection: Result<ParsedKey, Error>?
    @State private var passphrase = ""
    @State private var savePassphrase = false
    @State private var sync = false
    @State private var showPicker = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var error: String?

    init(
        onCreated: (() -> Void)? = nil,
        onCreatedKey: ((StoredKey) -> Void)? = nil
    ) {
        self.onCreated = onCreated
        self.onCreatedKey = onCreatedKey
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsed: ParsedKey? {
        if case .success(let key) = inspection { return key }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        switch error as? KeyFormatError {
        case .malformed(let reason): return "Invalid key: \(reason)."
        case .unsupported(let reason): return "Unsupported key: \(reason)."
        case nil: return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if trimmedName.isEmpty {
                        Text(parsed != nil ? "Enter a name above to enable Import." : "Give this key a name to identify it.")
                            .foregroundStyle(parsed != nil ? .orange : .secondary)
                    }
                }

                Section("Private key") {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("-----BEGIN OPENSSH PRIVATE KEY-----")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 140)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack(spacing: 16) {
                        Button("Choose file…", systemImage: "folder") {
                            showPicker = true
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button("Paste", systemImage: "doc.on.clipboard") {
                            pasteFromClipboard()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                switch inspection {
                case .success(let p):
                    Text("Detected: \(p.type.rawValue)\(p.isEncrypted ? ", passphrase-protected" : "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if p.isEncrypted {
                        Toggle("Save passphrase in Keychain", isOn: $savePassphrase)
                        if savePassphrase {
                            SecureField("Passphrase", text: $passphrase)
                        }
                    }
                case .failure(let parseError):
                    Text(Self.describe(parseError))
                        .font(.footnote)
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }

                Toggle("Sync via iCloud Keychain", isOn: $sync)

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .onChange(of: savePassphrase) { _, on in if !on { passphrase = "" } }
            .onChange(of: text) { _, newValue in
                error = nil
                passphrase = ""
                savePassphrase = false
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                inspection = trimmed.isEmpty ? nil : Result { try KeyImporter.inspect(newValue) }
            }
            .onDisappear {
                fileImportTask?.cancel()
                fileImportTask = nil
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let imported = try KeyImporter.importKey(
                                name: trimmedName,
                                text: text,
                                passphrase: savePassphrase && !passphrase.isEmpty ? passphrase : nil,
                                savePassphrase: savePassphrase,
                                syncsViaICloud: sync
                            )
                            AppHaptics.notify(.success)
                            onCreated?()
                            onCreatedKey?(imported)
                            dismiss()
                        } catch {
                            self.error = Self.describe(error)
                        }
                    }
                    .disabled(trimmedName.isEmpty || parsed == nil || (savePassphrase && passphrase.isEmpty))
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data, .text]) { result in
                loadImportedKeyFile(result)
            }
        }
    }

    private func loadImportedKeyFile(_ result: Result<URL, any Error>) {
        fileImportTask?.cancel()
        switch result {
        case .success(let url):
            fileImportTask = Task { @MainActor in
                defer { fileImportTask = nil }
                do {
                    let decoded = try await SecurityScopedFileReader.readText(
                        from: url,
                        maxBytes: Self.maxKeyFileBytes
                    )
                    guard !Task.isCancelled else { return }
                    text = decoded
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else {
            AppHaptics.notify(.warning)
            error = "Clipboard is empty."
            return
        }
        AppHaptics.impact(.light)
        text = pasted
        error = nil
    }
}
