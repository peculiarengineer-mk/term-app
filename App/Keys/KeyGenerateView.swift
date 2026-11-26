import SwiftUI
import UIKit
import Store
import TermUI

struct KeyGenerateView: View {
    let dismissOnCreate: Bool
    let onCreated: (() -> Void)?
    let onCreatedKey: ((StoredKey) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var name = ""
    @State private var comment = ""
    @State private var sync = false
    private enum Kind: Hashable { case enclave, ed25519 }
    @State private var kind: Kind = SecureEnclaveKey.isAvailable ? .enclave : .ed25519
    @State private var generatedKey: StoredKey?
    @State private var isGenerating = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var error: String?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(
        dismissOnCreate: Bool = false,
        onCreated: (() -> Void)? = nil,
        onCreatedKey: ((StoredKey) -> Void)? = nil
    ) {
        self.dismissOnCreate = dismissOnCreate
        self.onCreated = onCreated
        self.onCreatedKey = onCreatedKey
    }

    var body: some View {
        NavigationStack {
            Group {
                if let generatedKey {
                    handoffView(for: generatedKey)
                } else {
                    formView
                }
            }
            .navigationTitle(generatedKey == nil ? "Generate Key" : "Key Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if generatedKey == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Generate") { generateKey() }
                            .disabled(trimmedName.isEmpty || isGenerating)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onDisappear {
                copyResetTask?.cancel()
                copyResetTask = nil
            }
        }
    }

    private var formView: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Comment (optional)", text: $comment)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if SecureEnclaveKey.isAvailable {
                Picker("Key type", selection: $kind) {
                    Text("Secure Enclave (this device only)").tag(Kind.enclave)
                    Text("Ed25519").tag(Kind.ed25519)
                }
            }
            if kind == .enclave {
                Text("The private key is created inside this device's Secure Enclave and can never be copied off it, synced, or exported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Sync via iCloud Keychain", isOn: $sync)
                Text("Generates an Ed25519 key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    private func handoffView(for key: StoredKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)

                    Text(key.name)
                        .font(.title3.bold())

                    Text(key.type == .secureEnclaveP256 ? "Secure Enclave P-256" : key.type.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.14), in: Capsule())

                    Text("Add this public key to ~/.ssh/authorized_keys on any server you want to access.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(key.publicKey)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12),
                                lineWidth: 1
                            )
                    )

                VStack(spacing: 10) {
                    Button {
                        copyPublicKey(key.publicKey)
                    } label: {
                        Label(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if !key.publicKey.isEmpty {
                        ShareLink(item: key.publicKey) {
                            Label("Share Public Key", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func generateKey() {
        guard !isGenerating else { return }
        isGenerating = true
        error = nil
        do {
            let created: StoredKey
            if kind == .enclave {
                created = try SecureEnclaveKey.generateAndStore(name: trimmedName, comment: comment, store: KeyStore())
            } else {
                created = try KeyGenerator.generateAndStore(name: trimmedName, comment: comment, syncsViaICloud: sync)
            }
            AppHaptics.notify(.success)
            onCreated?()
            onCreatedKey?(created)
            if dismissOnCreate {
                dismiss()
            } else {
                generatedKey = created
                isGenerating = false
            }
        } catch {
            isGenerating = false
            self.error = error.localizedDescription
        }
    }

    private func copyPublicKey(_ publicKey: String) {
        UIPasteboard.general.string = publicKey
        AppHaptics.notify(.success)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
