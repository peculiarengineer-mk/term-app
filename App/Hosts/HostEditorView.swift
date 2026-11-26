import SwiftUI
import SwiftData
import Store
import TermUI

/// Saved passwords live in Keychain under the host's ID, never in SwiftData.
enum HostSecrets {
    static let passwordService = KeychainService.hostPassword
    static func readPassword(for id: UUID) throws -> String? {
        try KeychainStore().read(service: passwordService, account: id.uuidString)
            .map { String(decoding: $0, as: UTF8.self) }
    }
    static func password(for id: UUID) -> String? {
        try? readPassword(for: id)
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
    static func tryDeletePassword(for id: UUID) throws {
        try KeychainStore().delete(service: passwordService, account: id.uuidString)
    }
    static func deletePassword(for id: UUID) {
        try? tryDeletePassword(for: id)
    }
}

struct HostEditorView: View {
    private enum Field: Hashable {
        case label, hostname, port, user, password, tmux, tag
    }

    let host: Host?
    var onSaved: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Host.label) private var allHosts: [Host]
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var auth = "password"
    @State private var keyID: UUID?
    @State private var password = ""
    @State private var tmux = ""
    @State private var tmuxOn = false
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var proxyJumpHostID: UUID?
    @State private var forwardAgent = false
    /// The host inserted by a first Save, so a retried Save after a Keychain failure updates it
    /// instead of inserting a duplicate.
    @State private var created: Host?
    @State private var keys: [StoredKey] = []
    @State private var passwordLoaded = false
    @State private var didLoad = false
    @State private var showGenerateKey = false
    @State private var showImportKey = false
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var portValue: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed).flatMap { (1...65535).contains($0) ? $0 : nil }
    }
    private var isSelectedKeyMissing: Bool {
        guard let keyID else { return false }
        return !keys.contains { $0.id == keyID }
    }
    private var trimmedHost: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTagInput: String { tagInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var valid: Bool {
        !trimmedHost.isEmpty && !trimmedHost.contains(where: \.isWhitespace)
            && !trimmedUser.isEmpty && portValue != nil
            && (auth != "key" || (keyID != nil && keys.contains { $0.id == keyID }))
    }

    private var existingTagSuggestions: [String] {
        let allCleaned = allHosts.flatMap { Self.normalizedTags(from: $0.tags) }
        return Set(allCleaned)
            .filter { !tags.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var editingHostID: UUID? {
        host?.id ?? created?.id
    }

    private var eligibleJumpHosts: [Host] {
        allHosts.filter { candidate in
            SSHOptionsBuilder.canSelectJumpHost(candidate, forHostID: editingHostID, allHosts: allHosts)
        }
    }

    var body: some View {
        Form {
            Section("Host") {
                TextField("Label", text: $label)
                    .focused($focusedField, equals: .label)
                TextField("Hostname", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .hostname)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .port)
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .user)
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
                        if let keyID, !keys.contains(where: { $0.id == keyID }) {
                            Text("Missing Key").tag(UUID?.some(keyID))
                        }
                        ForEach(keys) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    if isSelectedKeyMissing {
                        Label(
                            "The selected key is missing or deleted from this device. Choose, generate, or import a key.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Button {
                        showGenerateKey = true
                    } label: {
                        Label("Generate Key", systemImage: "plus.circle")
                    }
                    Button {
                        showImportKey = true
                    } label: {
                        Label("Import Key", systemImage: "square.and.arrow.down")
                    }
                } else {
                    SecureField("Saved password (optional)", text: $password)
                        .focused($focusedField, equals: .password)
                }
            }

            Section("Tags") {
                if !tags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                removeTag(tag)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(tag)
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(theme.accentColor)
                                .background(theme.accentColor.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack(spacing: 8) {
                    TextField("Add tag", text: $tagInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .tag)
                        .submitLabel(.done)
                        .onSubmit { addTag(tagInput) }

                    Button("Add") {
                        addTag(tagInput)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(trimmedTagInput.isEmpty)
                }

                if !existingTagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggestions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(existingTagSuggestions, id: \.self) { suggestion in
                                    Button {
                                        addTag(suggestion)
                                    } label: {
                                        Label(suggestion, systemImage: "plus")
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .foregroundStyle(Color.primary)
                                            .background(Color.secondary.opacity(0.14), in: Capsule())
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Add tag \(suggestion)")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Session") {
                Toggle("Attach to tmux", isOn: $tmuxOn)
                if tmuxOn {
                    TextField(TmuxAttach.defaultCommand, text: $tmux)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .tmux)
                }
            }

            Section {
                Picker("Jump Host (ProxyJump)", selection: $proxyJumpHostID) {
                    Text("None").tag(UUID?.none)
                    if let currentJumpID = proxyJumpHostID,
                       !eligibleJumpHosts.contains(where: { $0.id == currentJumpID }) {
                        Text("Unavailable Host").tag(UUID?.some(currentJumpID))
                    }
                    ForEach(eligibleJumpHosts) { candidate in
                        Text(jumpHostOptionLabel(for: candidate)).tag(UUID?.some(candidate.id))
                    }
                }

                Toggle("Forward SSH Agent (-A)", isOn: $forwardAgent)
            } header: {
                Text("Jump Host & Agent")
            } footer: {
                Text("Allows this server to authenticate using your local SSH keys while connected. Only enable on hosts you trust.")
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(host == nil ? "New host" : "Edit host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .sheet(isPresented: $showGenerateKey) {
            KeyGenerateView(onCreatedKey: { newKey in
                reloadKeysAndSelect(newKey.id)
            })
        }
        .sheet(isPresented: $showImportKey) {
            KeyImportView(onCreatedKey: { newKey in
                reloadKeysAndSelect(newKey.id)
            })
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
    }

    private static func normalizedTags(from rawTags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawTags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private func addTag(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !tags.contains(trimmed) {
            tags.append(trimmed)
            AppHaptics.impact(.light)
        }
        tagInput = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        AppHaptics.impact(.light)
    }

    private func jumpHostOptionLabel(for candidate: Host) -> String {
        let trimmedLabel = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = candidate.port == 22 ? candidate.hostname : "\(candidate.hostname):\(candidate.port)"
        if trimmedLabel.isEmpty {
            return endpoint
        }
        if trimmedLabel.caseInsensitiveCompare(candidate.hostname) == .orderedSame {
            return candidate.port == 22 ? trimmedLabel : "\(trimmedLabel):\(candidate.port)"
        }
        return "\(trimmedLabel) (\(endpoint))"
    }

    private func reloadKeysAndSelect(_ newKeyID: UUID) {
        do {
            keys = try KeyStore().list()
            keyID = newKeyID
        } catch {
            self.error = "Could not load SSH keys: \(error.localizedDescription)"
        }
    }

    private func load() {
        var loadErrors: [String] = []
        do {
            keys = try KeyStore().list()
        } catch {
            keys = []
            loadErrors.append("Could not load SSH keys: \(error.localizedDescription)")
        }
        guard let host else {
            passwordLoaded = true
            error = loadErrors.isEmpty ? nil : loadErrors.joined(separator: "\n")
            return
        }
        label = host.label
        hostname = host.hostname
        port = String(host.port)
        user = host.username
        auth = host.authMethod
        keyID = host.keyID
        tmuxOn = host.tmuxCommand != nil
        tmux = host.tmuxCommand ?? ""
        tags = Self.normalizedTags(from: host.tags)
        proxyJumpHostID = host.proxyJumpHostID
        forwardAgent = host.forwardAgent
        do {
            password = try HostSecrets.readPassword(for: host.id) ?? ""
            passwordLoaded = true
        } catch {
            password = ""
            passwordLoaded = false
            loadErrors.append("Could not read saved password: \(error.localizedDescription)")
        }
        error = loadErrors.isEmpty ? nil : loadErrors.joined(separator: "\n")
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
        target.tags = Self.normalizedTags(from: tags)
        let t = tmux.trimmingCharacters(in: .whitespacesAndNewlines)
        // nil = off, empty = the default command
        target.tmuxCommand = tmuxOn ? t : nil
        target.proxyJumpHostID = proxyJumpHostID
        target.forwardAgent = forwardAgent
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
            } else if passwordLoaded {
                try HostSecrets.tryDeletePassword(for: target.id)
            }
            onSaved?()
            dismiss()
        } catch {
            let action = (auth != "key" && !password.isEmpty) ? "stored" : "removed"
            self.error = "Host saved, but the password could not be \(action): \(error.localizedDescription)"
        }
    }
}
