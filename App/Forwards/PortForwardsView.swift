import SwiftUI
import SSHKit
import Store
import TermUI

/// Sheet for managing local SSH port forwards (`-L`) for a specific host and active `SSHConnection`.
struct PortForwardsView: View {
    private enum EditorTarget: Identifiable {
        case new
        case edit(SavedPortForward)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let rule): rule.id.uuidString
            }
        }

        var existingRule: SavedPortForward? {
            switch self {
            case .new: nil
            case .edit(let rule): rule
            }
        }
    }

    let connection: SSHConnection
    let hostID: UUID
    let hostTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var savedRules: [SavedPortForward] = []
    @State private var activeForwards: [ActivePortForward] = []
    @State private var isLoading = true
    @State private var busyRuleIDs: Set<UUID> = []
    @State private var editorTarget: EditorTarget?
    @State private var errorMessage: String?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var activeByID: [UUID: ActivePortForward] {
        Dictionary(uniqueKeysWithValues: activeForwards.map { ($0.id, $0) })
    }

    private var savedRuleIDs: Set<UUID> {
        Set(savedRules.map(\.id))
    }

    private var sortedAdHocActiveForwards: [ActivePortForward] {
        activeForwards
            .filter { !savedRuleIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let leftName = displayTitle(for: lhs.rule)
                let rightName = displayTitle(for: rhs.rule)
                let cmp = leftName.localizedCaseInsensitiveCompare(rightName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.boundLocalPort < rhs.boundLocalPort
            }
    }

    var body: some View {
        NavigationStack {
            List {
                if !sortedAdHocActiveForwards.isEmpty {
                    Section("Active Tunnels") {
                        ForEach(sortedAdHocActiveForwards) { active in
                            activeForwardRow(active)
                        }
                    }
                }

                if !savedRules.isEmpty {
                    Section("Saved Rules") {
                        ForEach(savedRules) { rule in
                            savedRuleRow(rule)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if isLoading && activeForwards.isEmpty && savedRules.isEmpty {
                    ProgressView("Loading Port Forwards…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !isLoading && sortedAdHocActiveForwards.isEmpty && savedRules.isEmpty {
                    ContentUnavailableView {
                        Label("No Port Forwards", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text("Forward a remote TCP port (such as localhost:3000 or 8006) to 127.0.0.1 on this device.")
                    } actions: {
                        Button("New Port Forward") {
                            AppHaptics.impact(.light)
                            editorTarget = .new
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                    }
                }
            }
            .refreshable {
                await reload()
            }
            .navigationTitle("Port Forwards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        AppHaptics.impact(.light)
                        editorTarget = .new
                    } label: {
                        Label("Add Forward", systemImage: "plus.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }
            }
            .task {
                await reload()
            }
            .sheet(item: $editorTarget) { target in
                PortForwardEditorView(hostID: hostID, existing: target.existingRule) { saved in
                    Task { await handleSavedRule(saved, previous: target.existingRule) }
                }
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(palette.accent)
            }
            .alert(
                "Port Forward Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func activeForwardRow(_ active: ActivePortForward) -> some View {
        let isBusy = busyRuleIDs.contains(active.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProStatusLED(color: palette.healthy, size: 8, glow: true)

                Text(displayTitle(for: active.rule))
                    .font(.headline)
                    .lineLimit(1)

                Spacer()
            }

            Text("127.0.0.1:\(active.boundLocalPort) → \(active.rule.remoteHost):\(active.rule.remotePort)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                if let url = active.localURL {
                    Button {
                        AppHaptics.impact(.light)
                        openURL(url)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(role: .destructive) {
                    AppHaptics.impact(.light)
                    Task { await stopForward(id: active.id) }
                } label: {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func savedRuleRow(_ rule: SavedPortForward) -> some View {
        let active = activeByID[rule.id]
        let isRunning = active != nil
        let isBusy = busyRuleIDs.contains(rule.id)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isRunning {
                        ProStatusLED(color: palette.healthy, size: 7, glow: true)
                    }

                    Text(rule.displayTitle)
                        .font(.headline)
                        .lineLimit(1)

                    if rule.autoStart {
                        Text("Auto")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(palette.accent)
                            .background(
                                palette.pillFill(for: palette.accent),
                                in: Capsule()
                            )
                    }
                }

                Text(routeLabel(for: rule, active: active))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let url = active?.localURL {
                    Button {
                        AppHaptics.impact(.light)
                        openURL(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Open in Safari")
                }

                Button {
                    AppHaptics.impact(.light)
                    Task {
                        if isRunning {
                            await stopForward(id: rule.id)
                        } else {
                            await startForward(from: rule)
                        }
                    }
                } label: {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(isRunning ? "Stop" : "Start")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isRunning ? palette.critical : palette.accent)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await deleteRule(rule) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editorTarget = .edit(rule)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button(
                isRunning ? "Stop" : "Start",
                systemImage: isRunning ? "stop.fill" : "play.fill"
            ) {
                Task {
                    if isRunning {
                        await stopForward(id: rule.id)
                    } else {
                        await startForward(from: rule)
                    }
                }
            }
            if let url = active?.localURL {
                Button("Open in Safari", systemImage: "safari") {
                    openURL(url)
                }
            }
            Button("Edit", systemImage: "pencil") {
                editorTarget = .edit(rule)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await deleteRule(rule) }
            }
        }
    }

    private func displayTitle(for rule: PortForwardRule) -> String {
        let trimmed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(rule.remoteHost):\(rule.remotePort)" : trimmed
    }

    private func routeLabel(for rule: SavedPortForward, active: ActivePortForward?) -> String {
        if let active {
            return "127.0.0.1:\(active.boundLocalPort) → \(rule.remoteHost):\(rule.remotePort)"
        }
        return rule.routeDescription
    }

    private func reload() async {
        savedRules = PortForwardStore.list(for: hostID)
        activeForwards = await connection.activePortForwards()
        isLoading = false
    }

    private func startForward(from rule: SavedPortForward) async {
        busyRuleIDs.insert(rule.id)
        defer { busyRuleIDs.remove(rule.id) }

        do {
            _ = try await connection.startLocalForward(
                PortForwardRule(
                    id: rule.id,
                    name: rule.name,
                    localPort: rule.localPort,
                    remoteHost: rule.remoteHost,
                    remotePort: rule.remotePort
                )
            )
            AppHaptics.notify(.success)
        } catch {
            AppHaptics.notify(.error)
            errorMessage = "Could not start forward: \(error.localizedDescription)"
        }
        await reload()
    }

    private func stopForward(id: UUID) async {
        busyRuleIDs.insert(id)
        defer { busyRuleIDs.remove(id) }

        await connection.stopLocalForward(id: id)
        await reload()
    }

    private func deleteRule(_ rule: SavedPortForward) async {
        busyRuleIDs.insert(rule.id)
        defer { busyRuleIDs.remove(rule.id) }

        if activeByID[rule.id] != nil {
            await connection.stopLocalForward(id: rule.id)
        }
        PortForwardStore.delete(id: rule.id)
        AppHaptics.notify(.warning)
        await reload()
    }

    private func handleSavedRule(_ saved: SavedPortForward, previous: SavedPortForward?) async {
        if let previous,
           activeByID[saved.id] != nil,
           (previous.localPort != saved.localPort
            || previous.remoteHost != saved.remoteHost
            || previous.remotePort != saved.remotePort
            || previous.name != saved.name) {
            await connection.stopLocalForward(id: saved.id)
        }
        await reload()
    }
}

/// Modal form for creating or editing a `SavedPortForward` rule.
private struct PortForwardEditorView: View {
    private enum Field: Hashable {
        case name, localPort, remoteHost, remotePort
    }

    let hostID: UUID
    let existing: SavedPortForward?
    let onSave: (SavedPortForward) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var localPortText: String
    @State private var remoteHost: String
    @State private var remotePortText: String
    @State private var autoStart: Bool
    @FocusState private var focusedField: Field?

    init(hostID: UUID, existing: SavedPortForward?, onSave: @escaping (SavedPortForward) -> Void) {
        self.hostID = hostID
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _localPortText = State(initialValue: existing.map { String($0.localPort) } ?? "0")
        _remoteHost = State(initialValue: existing?.remoteHost ?? "127.0.0.1")
        _remotePortText = State(initialValue: existing.map { String($0.remotePort) } ?? "")
        _autoStart = State(initialValue: existing?.autoStart ?? false)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRemoteHost: String {
        remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedLocalPort: UInt16? {
        let trimmed = localPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return UInt16(trimmed)
    }

    private var parsedRemotePort: UInt16? {
        let trimmed = remotePortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmed), port > 0 else { return nil }
        return port
    }

    private var isValid: Bool {
        parsedLocalPort != nil
            && !trimmedRemoteHost.isEmpty
            && !trimmedRemoteHost.contains(where: \.isWhitespace)
            && parsedRemotePort != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") {
                    TextField("Name (e.g. Proxmox, Grafana)", text: $name)
                        .focused($focusedField, equals: .name)
                }

                Section {
                    HStack {
                        Text("Local Port")
                        Spacer()
                        TextField("0 = auto", text: $localPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .focused($focusedField, equals: .localPort)
                    }

                    HStack {
                        Text("Remote Host")
                        Spacer()
                        TextField("127.0.0.1", text: $remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .focused($focusedField, equals: .remoteHost)
                    }

                    HStack {
                        Text("Remote Port")
                        Spacer()
                        TextField("e.g. 8006", text: $remotePortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .focused($focusedField, equals: .remotePort)
                    }
                } header: {
                    Text("Tunnel (-L)")
                } footer: {
                    Text("Local port 0 automatically picks an available port on 127.0.0.1.")
                }

                Section {
                    Toggle("Auto-start on connect", isOn: $autoStart)
                }
            }
            .navigationTitle(existing == nil ? "New Port Forward" : "Edit Port Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
    }

    private func save() {
        guard let localPort = parsedLocalPort,
              let remotePort = parsedRemotePort,
              !trimmedRemoteHost.isEmpty else {
            return
        }
        let saved = SavedPortForward(
            id: existing?.id ?? UUID(),
            hostID: hostID,
            name: trimmedName,
            localPort: localPort,
            remoteHost: trimmedRemoteHost,
            remotePort: remotePort,
            autoStart: autoStart
        )
        PortForwardStore.upsert(saved)
        AppHaptics.notify(.success)
        onSave(saved)
        dismiss()
    }
}
