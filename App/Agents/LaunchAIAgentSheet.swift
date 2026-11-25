import SwiftUI
import SwiftData
import SSHKit
import Store
import TermUI

/// Sheet for configuring and launching a `tmux`-backed AI agent session on a saved `Host`.
struct LaunchAIAgentSheet: View {
    let initialHost: Host?

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ProStore.self) private var proStore
    @Environment(\.launchAIAgent) private var launchAIAgent
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var hosts: [Host]

    @State private var selectedHostID: UUID?
    @State private var presets: [AIAgentDescriptor] = HostProjectStore.allPresets()
    @State private var selectedAgentID: String = BuiltInAIAgent.claude.id
    @State private var workingDirectory: String = "~"
    @State private var extraArgs: String = ""
    @State private var favorites: [String] = []
    @State private var recents: [String] = []
    @State private var showingFolderPicker = false
    @State private var showingCustomPresetSheet = false
    @State private var showingPaywall = false
    @State private var didInitialize = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var availableHosts: [Host] {
        if let initialHost, !hosts.contains(where: { $0.id == initialHost.id }) {
            return [initialHost] + hosts
        }
        return hosts
    }

    private var selectedHost: Host? {
        if let selectedHostID,
           let match = availableHosts.first(where: { $0.id == selectedHostID }) {
            return match
        }
        return initialHost ?? availableHosts.first
    }

    private var selectedAgent: AIAgentDescriptor {
        presets.first(where: { $0.id == selectedAgentID })
            ?? presets.first
            ?? AIAgentDescriptor(builtIn: .claude)
    }

    private var normalizedWorkingDirectory: String {
        var trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "~" }
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private var isFavoriteDirectory: Bool {
        favorites.contains(normalizedWorkingDirectory)
    }

    private var computedSessionName: String {
        TMuxSessionHelper.sessionName(agentSlug: selectedAgent.slug, workingDirectory: normalizedWorkingDirectory)
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableHosts.isEmpty {
                    ContentUnavailableView(
                        "No Saved Hosts",
                        systemImage: "server.rack",
                        description: Text("Add an SSH host first before launching an AI agent session.")
                    )
                } else {
                    launchForm
                }
            }
            .navigationTitle("Launch AI Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Launch") {
                        launchSession()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedHost == nil)
                }
            }
            .onAppear {
                if !didInitialize {
                    didInitialize = true
                    presets = HostProjectStore.allPresets()
                    let initial = initialHost ?? availableHosts.first
                    selectedHostID = initial?.id
                    if let initial {
                        applyHostDefaults(for: initial.id)
                    }
                }
            }
            .sheet(isPresented: $showingFolderPicker) {
                if let host = selectedHost {
                    RemoteFolderPickerSheet(
                        target: AgentHostTarget(host: host, sessionManager: sessionManager),
                        initialPath: normalizedWorkingDirectory
                    ) { chosenPath in
                        workingDirectory = chosenPath
                    }
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(theme.accentColor)
                }
            }
            .sheet(isPresented: $showingCustomPresetSheet) {
                CustomPresetEditorSheet(
                    onSave: { preset in
                        HostProjectStore.saveCustomPreset(preset)
                        presets = HostProjectStore.allPresets()
                        selectedAgentID = preset.id.uuidString
                    },
                    onDelete: { deletedID in
                        HostProjectStore.deleteCustomPreset(id: deletedID)
                        presets = HostProjectStore.allPresets()
                        if selectedAgentID == deletedID.uuidString {
                            selectedAgentID = BuiltInAIAgent.claude.id
                        }
                    }
                )
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView()
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(theme.accentColor)
            }
        }
    }

    private var launchForm: some View {
        Form {
            hostSection
            agentSection
            directorySection
            optionsSection
            launchButtonSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var hostSection: some View {
        Section("Target Host") {
            if let initialHost {
                hostSummaryRow(initialHost)
            } else if availableHosts.count == 1, let onlyHost = availableHosts.first {
                hostSummaryRow(onlyHost)
            } else {
                hostPicker
                if let host = selectedHost {
                    hostSummaryRow(host)
                }
            }
        }
    }

    private var hostPicker: some View {
        Picker("Host", selection: Binding(
            get: { selectedHostID ?? availableHosts.first?.id ?? UUID() },
            set: { newID in
                AppHaptics.impact(.light)
                selectedHostID = newID
                applyHostDefaults(for: newID)
            }
        )) {
            ForEach(availableHosts) { host in
                Text(hostDisplayLabel(host)).tag(host.id)
            }
        }
    }

    private func hostSummaryRow(_ host: Host) -> some View {
        HStack(spacing: 12) {
            HostEnvironmentIcon(host: host)
            VStack(alignment: .leading, spacing: 2) {
                Text(hostDisplayLabel(host))
                    .font(.headline)
                Text(hostSubtitle(host))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sessionManager.connectedSession(for: host.id) != nil {
                HStack(spacing: 5) {
                    CloudStatusLED(color: AgentVisuals.activeGreen, size: 7)
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentVisuals.activeGreen)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var agentSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { preset in
                        agentCard(preset)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            HStack {
                Text("AI Agent")
                Spacer()
                Button {
                    AppHaptics.impact(.light)
                    showingCustomPresetSheet = true
                } label: {
                    Label("Custom", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        } footer: {
            if !selectedAgent.defaultArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Default flags: \(selectedAgent.defaultArgs)")
                    .font(.caption.monospaced())
            }
        }
    }

    private func agentCard(_ preset: AIAgentDescriptor) -> some View {
        let isSelected = selectedAgent.id == preset.id
        let tint = AgentVisuals.agentTint(for: preset)
        let cardFill = isSelected
            ? tint.opacity(theme.isDark ? 0.22 : 0.14)
            : (theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        let cardStroke = isSelected
            ? tint.opacity(0.75)
            : (theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))

        return Button {
            AppHaptics.impact(.light)
            selectedAgentID = preset.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SquircleIcon(
                        symbolName: AgentVisuals.agentSymbol(for: preset),
                        tint: tint,
                        fillOpacity: theme.isDark ? 0.24 : 0.16,
                        rimOpacity: 0.40,
                        size: 32
                    )
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(preset.command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 118, alignment: .leading)
            .padding(10)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name), command \(preset.command)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if !preset.isBuiltIn, let uuid = UUID(uuidString: preset.id) {
                Button("Delete Preset", systemImage: "trash", role: .destructive) {
                    HostProjectStore.deleteCustomPreset(id: uuid)
                    presets = HostProjectStore.allPresets()
                    if selectedAgentID == preset.id {
                        selectedAgentID = BuiltInAIAgent.claude.id
                    }
                }
            }
        }
    }

    private var directorySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(AgentVisuals.appleProAmber)
                    .accessibilityHidden(true)

                TextField("~/projects/my-app", text: $workingDirectory)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    toggleFavoriteDirectory()
                } label: {
                    Image(systemName: isFavoriteDirectory ? "star.fill" : "star")
                        .font(.body)
                        .foregroundStyle(isFavoriteDirectory ? AgentVisuals.appleProAmber : .secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavoriteDirectory ? "Remove favorite folder" : "Add favorite folder")
            }

            Button {
                AppHaptics.impact(.light)
                showingFolderPicker = true
            } label: {
                Label("Browse Remote Folders…", systemImage: "folder.badge.gearshape")
            }
            .disabled(selectedHost == nil)

            if !favorites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Favorites")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    pathChipStrip(paths: favorites, icon: "star.fill", iconColor: AgentVisuals.appleProAmber)
                }
                .padding(.vertical, 2)
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    pathChipStrip(paths: recents, icon: "clock", iconColor: .secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Project Directory")
        }
    }

    private func pathChipStrip(paths: [String], icon: String, iconColor: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    let isSelected = normalizedWorkingDirectory == path
                    Button {
                        AppHaptics.impact(.light)
                        workingDirectory = path
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: icon)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? AgentVisuals.appleProAmber : iconColor)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? AgentVisuals.appleProAmber : .primary)
                        .background(
                            isSelected
                                ? AgentVisuals.appleProAmber.opacity(theme.isDark ? 0.20 : 0.14)
                                : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? AgentVisuals.appleProAmber.opacity(0.55) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            HStack(spacing: 10) {
                Text("Extra Flags")
                    .foregroundStyle(.secondary)
                TextField("e.g. --model sonnet", text: $extraArgs)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: 10) {
                Text("tmux Session")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(computedSessionName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("Session Options")
        } footer: {
            Text("Relaunching in the same project directory reattaches to this persistent tmux session.")
        }
    }

    private var launchButtonSection: some View {
        Section {
            Button {
                launchSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AgentVisuals.agentSymbol(for: selectedAgent))
                    Text("Launch \(selectedAgent.name)")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AgentVisuals.agentTint(for: selectedAgent))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .disabled(selectedHost == nil)
        }
    }

    private func applyHostDefaults(for hostID: UUID) {
        let hostFavorites = HostProjectStore.favorites(for: hostID)
        let hostRecents = HostProjectStore.recents(for: hostID)
        favorites = hostFavorites
        recents = hostRecents

        if let recent = hostRecents.first {
            workingDirectory = recent
        } else if let fav = hostFavorites.first {
            workingDirectory = fav
        } else {
            workingDirectory = "~"
        }

        if let lastID = HostProjectStore.lastAgentID(for: hostID),
           presets.contains(where: { $0.id == lastID }) {
            selectedAgentID = lastID
        } else {
            selectedAgentID = BuiltInAIAgent.claude.id
        }
    }

    private func toggleFavoriteDirectory() {
        guard let host = selectedHost else { return }
        AppHaptics.impact(.light)
        let path = normalizedWorkingDirectory
        if isFavoriteDirectory {
            HostProjectStore.removeFavorite(path, for: host.id)
        } else {
            HostProjectStore.addFavorite(path, for: host.id)
        }
        favorites = HostProjectStore.favorites(for: host.id)
    }

    private func launchSession() {
        guard proStore.isProUnlocked else {
            showingPaywall = true
            return
        }
        guard let host = selectedHost else { return }

        let dir = normalizedWorkingDirectory
        let agent = selectedAgent
        let sessionName = computedSessionName
        let trimmedExtra = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)

        HostProjectStore.recordRecent(dir, for: host.id)
        HostProjectStore.setLastAgentID(agent.id, for: host.id)

        let command = TMuxSessionHelper.launchOrAttachCommand(
            agent: agent,
            workingDirectory: dir,
            extraArgs: trimmedExtra,
            sessionName: sessionName
        )
        let context = AIAgentLaunchContext(
            agent: agent,
            sessionName: sessionName,
            workingDirectory: dir,
            hostID: host.id
        )

        AppHaptics.notify(.success)
        dismiss()
        launchAIAgent?(host, context, command)
    }

    private func hostDisplayLabel(_ host: Host) -> String {
        host.label.isEmpty ? host.hostname : host.label
    }

    private func hostSubtitle(_ host: Host) -> String {
        let userPart = host.username.isEmpty ? "" : "\(host.username)@"
        let portPart = host.port == 22 ? "" : ":\(host.port)"
        return "\(userPart)\(host.hostname)\(portPart)"
    }
}

/// Interactive remote directory browser over active `LiveSession.exec` or non-interactive `SSHExec`.
struct RemoteFolderPickerSheet: View {
    let target: AgentHostTarget
    let initialPath: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var browsingPath: String
    @State private var resolvedPath: String = ""
    @State private var directories: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    init(target: AgentHostTarget, initialPath: String, onSelect: @escaping (String) -> Void) {
        self.target = target
        self.initialPath = initialPath
        self.onSelect = onSelect
        _browsingPath = State(initialValue: initialPath.isEmpty ? "~" : initialPath)
    }

    private var displayedPath: String {
        resolvedPath.isEmpty ? browsingPath : resolvedPath
    }

    private var parentDirectoryPath: String? {
        let path = displayedPath
        guard !path.isEmpty, path != "/", path != "~" else { return nil }
        if path.hasPrefix("~/") {
            let trimmed = String(path.dropFirst(2))
            if !trimmed.contains("/") { return "~" }
            let parent = (trimmed as NSString).deletingLastPathComponent
            return parent.isEmpty ? "~" : "~/" + parent
        }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var body: some View {
        NavigationStack {
            List {
                if let parent = parentDirectoryPath {
                    Button {
                        AppHaptics.impact(.light)
                        loadDirectory(at: parent)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.left.square.fill")
                                .foregroundStyle(AgentVisuals.appleProAmber)
                            Text("..")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            Spacer()
                            Text("Parent Folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isLoading)
                }

                ForEach(directories, id: \.self) { folder in
                    Button {
                        AppHaptics.impact(.light)
                        let base = displayedPath
                        let nextPath = base == "/" ? "/\(folder)" : "\(base)/\(folder)"
                        loadDirectory(at: nextPath)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(AgentVisuals.appleProAmber)
                            Text(folder)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(displayedPath)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        AppHaptics.notify(.success)
                        onSelect(displayedPath)
                        dismiss()
                    } label: {
                        Label("Select This Folder", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(AgentVisuals.appleProAmber)
                    .disabled(isLoading && resolvedPath.isEmpty)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(.bar)
            }
            .overlay {
                if let errorMessage, directories.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("Unable to Browse", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        HStack(spacing: 12) {
                            Button("Home (~)") {
                                loadDirectory(at: "~")
                            }
                            .buttonStyle(.bordered)
                            Button("Retry") {
                                loadDirectory(at: browsingPath)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else if !isLoading && errorMessage == nil && directories.isEmpty {
                    ContentUnavailableView(
                        "No Subfolders",
                        systemImage: "folder",
                        description: Text("You can select \"\(displayedPath)\" or navigate up.")
                    )
                }
            }
            .navigationTitle(target.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.impact(.light)
                        loadDirectory(at: "~")
                    } label: {
                        Image(systemName: "house")
                    }
                    .accessibilityLabel("Go to home directory")
                    .disabled(isLoading)
                }
            }
            .task {
                await fetchDirectory(path: browsingPath, allowHomeFallback: browsingPath != "~")
            }
        }
    }

    private func loadDirectory(at path: String) {
        browsingPath = path
        Task {
            await fetchDirectory(path: path, allowHomeFallback: false)
        }
    }

    private func fetchDirectory(path: String, allowHomeFallback: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil

        do {
            let result = try await AgentAuthHelper.exec(
                TMuxSessionHelper.listDirectoriesCommand(in: path),
                on: target
            )
            guard !Task.isCancelled, generation == loadGeneration else { return }

            let listing = TMuxSessionHelper.parseDirectoryListing(from: result.stdout)
            if listing.currentPath.isEmpty {
                if allowHomeFallback && path != "~" {
                    await fetchDirectory(path: "~", allowHomeFallback: false)
                    return
                }
                errorMessage = "Folder \"\(path)\" was not found on \(target.displayName)."
                directories = []
            } else {
                resolvedPath = listing.currentPath
                browsingPath = listing.currentPath
                directories = listing.directories
            }
            isLoading = false
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            directories = []
            isLoading = false
        }
    }
}

/// Sheet for adding and managing user-defined `CustomAIAgentPreset`s in `HostProjectStore`.
struct CustomPresetEditorSheet: View {
    let onSave: (CustomAIAgentPreset) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var defaultArgs = ""
    @State private var symbolName = "terminal"
    @State private var customPresets: [CustomAIAgentPreset] = HostProjectStore.customPresets()

    private static let symbolChoices = [
        "terminal", "sparkles", "wand.and.stars", "cpu", "bolt.fill", "wrench.and.screwdriver", "brain",
    ]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Custom Agent") {
                    TextField("Display Name (e.g. Goose)", text: $name)
                    TextField("CLI Command (e.g. goose session)", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Default Flags (optional)", text: $defaultArgs)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.symbolChoices, id: \.self) { symbol in
                                let selected = symbolName == symbol
                                Button {
                                    AppHaptics.impact(.light)
                                    symbolName = symbol
                                } label: {
                                    SquircleIcon(
                                        symbolName: symbol,
                                        tint: selected ? AgentVisuals.appleProAmber : AgentVisuals.slateColor,
                                        fillOpacity: selected ? 0.24 : 0.12,
                                        rimOpacity: selected ? 0.55 : 0.25,
                                        size: 36
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Icon \(symbol)")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        let preset = CustomAIAgentPreset(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                            defaultArgs: defaultArgs.trimmingCharacters(in: .whitespacesAndNewlines),
                            symbolName: symbolName
                        )
                        AppHaptics.notify(.success)
                        onSave(preset)
                        dismiss()
                    } label: {
                        Text("Save Custom Preset")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentVisuals.appleProAmber)
                    .disabled(!canSave)
                }

                if !customPresets.isEmpty {
                    Section("Saved Custom Presets") {
                        ForEach(customPresets) { preset in
                            HStack(spacing: 12) {
                                SquircleIcon(
                                    symbolName: preset.symbolName,
                                    tint: AgentVisuals.slateColor,
                                    fillOpacity: 0.18,
                                    rimOpacity: 0.34,
                                    size: 32
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.headline)
                                    Text(preset.defaultArgs.isEmpty ? preset.command : "\(preset.command) \(preset.defaultArgs)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    AppHaptics.impact(.light)
                                    onDelete(preset.id)
                                    customPresets = HostProjectStore.customPresets()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(preset.name)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Custom AI Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
