import SwiftUI
import SwiftData
import Store

/// Saved passwords live in Keychain under the host's ID, never in SwiftData.
enum HostSecrets {
    static let passwordService = KeychainService.hostPassword
    static func password(for id: UUID) -> String? {
        (try? KeychainStore().read(service: passwordService, account: id.uuidString))
            .flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }
    static func savePassword(_ pw: String, for id: UUID) throws {
        let keychain = KeychainStore()
        let account = id.uuidString
        // A save never turns an already-synced password local; a failed lookup throws instead of guessing.
        let hasSynced = try keychain.readAll(service: passwordService)
            .contains { $0.account == account && $0.synchronizable }
        try keychain.save(Data(pw.utf8), service: passwordService, account: account,
                          synchronizable: AppContainer.syncEnabledAtLaunch || hasSynced)
    }
    static func deletePassword(for id: UUID) {
        try? KeychainStore().delete(service: passwordService, account: id.uuidString)
    }
}

struct HostEditorView: View {
    let host: Host?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var auth = "password"
    @State private var keyID: UUID?
    @State private var password = ""
    @State private var tmux = ""
    @State private var tmuxOn = false
    /// The host inserted by a first Save, so a retried Save after a Keychain failure updates it
    /// instead of inserting a duplicate.
    @State private var created: Host?
    @State private var keys: [StoredKey] = []
    @State private var error: String?

    private var portValue: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var trimmedHost: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !trimmedHost.isEmpty && !trimmedHost.contains(where: \.isWhitespace)
            && !trimmedUser.isEmpty && portValue != nil
            && (auth != "key" || keyID != nil)
    }

    var body: some View {
        Form {
            Section("Host") {
                TextField("Label", text: $label)
                TextField("Hostname", text: $hostname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Authentication") {
                Picker("Method", selection: $auth) {
                    Text("Password").tag("password")
                    Text("Key").tag("key")
                    Text("Keyboard-interactive").tag("keyboardInteractive")
                }
                if auth == "key" {
                    Picker("Key", selection: $keyID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(keys) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } else {
                    SecureField("Saved password (optional)", text: $password)
                }
            }
            Section("Session") {
                Toggle("Attach to tmux", isOn: $tmuxOn)
                if tmuxOn {
                    TextField(TmuxAttach.defaultCommand, text: $tmux)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(host == nil ? "New host" : "Edit host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        keys = (try? KeyStore().list()) ?? []
        guard let host else { return }
        label = host.label; hostname = host.hostname; port = String(host.port)
        user = host.username; auth = host.authMethod; keyID = host.keyID
        tmuxOn = host.tmuxCommand != nil
        tmux = host.tmuxCommand ?? ""
        password = HostSecrets.password(for: host.id) ?? ""
    }

    private func save() {
        guard let portValue else { return }
        let isNew = host == nil && created == nil
        let target = host ?? created ?? Host()
        target.label = label
        target.hostname = trimmedHost
        target.port = portValue
        target.username = trimmedUser
        target.authMethod = auth
        target.keyID = auth == "key" ? keyID : nil
        let t = tmux.trimmingCharacters(in: .whitespacesAndNewlines)
        // nil = off, empty = the default command
        target.tmuxCommand = tmuxOn ? t : nil
        target.touch()
        do {
            if isNew { context.insert(target) }
            try context.save()
            if isNew { created = target }
        } catch {
            context.rollback()
            self.error = "Could not save: \(error.localizedDescription)"
            return
        }
        do {
            if auth != "key", !password.isEmpty {
                try HostSecrets.savePassword(password, for: target.id)
            } else {
                HostSecrets.deletePassword(for: target.id)
            }
            dismiss()
        } catch {
            self.error = "Host saved, but the password could not be stored: \(error.localizedDescription)"
        }
    }
}
