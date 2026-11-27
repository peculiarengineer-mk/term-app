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
    @Environment(\.runTerminalCommand) private var runTerminalCommand
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var hosts: [Host]

    @State private var selectedHostID: UUID?
    @State private var presets: [AIAgentDescriptor] = HostProjectStore.allPresets()
    @State private var selectedAgentID: String = BuiltInAIAgent.claude.id
    @State private var workingDirectory: String = "~"
    @State private var extraArgs: String = ""
    @State private var reattachExisting: Bool = false
    @State private var sessionLabel: String = ""
    @State private var favorites: [String] = []
    @State private var recents: [String] = []
    @State private var showingFolderPicker = false
    @State private var showingCustomPresetSheet = false
    @State private var showingPaywall = false
    @State private var didInitialize = false
    @State private var tmuxAvailability: TMuxSessionHelper.TMuxAvailability?
    @State private var isInstallingTmux = false
    @State private var tmuxInstallError: String?
    @State private var tmuxRequiresInteractiveInstall = false
    @State private var tmuxJustInstalled = false
    @State private var tmuxProbeGeneration = 0
    @State private var tmuxInstallTask: Task<Void, Never>?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

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

    private var resolvedSessionName: String {
        _ = sessionManager.cacheRevision
        return Self.resolveSessionName(
            agentSlug: selectedAgent.slug,
            workingDirectory: normalizedWorkingDirectory,
            existingNames: Self.knownSessionNames(
                for: selectedHost?.id,
                openSessions: sessionManager.sessions,
                cacheDefaults: sessionManager.cacheDefaults
            ),
            customSuffix: sessionLabel,
            reattachExisting: reattachExisting
        )
    }

    static func knownSessionNames(
        for hostID: UUID?,
        openSessions: [LiveSession],
        cacheDefaults: UserDefaults = .standard
    ) -> Set<String> {
        guard let hostID else { return [] }
        var names = Set<String>()
        for live in openSessions where live.hostID == hostID {
            if let sessionName = live.aiAgentContext?.sessionName, !sessionName.isEmpty {
                names.insert(sessionName)
            }
        }
        for cached in AISessionCacheStore.load(defaults: cacheDefaults) where cached.hostID == hostID {
            if !cached.sessionName.isEmpty {
                names.insert(cached.sessionName)
            }
        }
        return names
    }

    static func resolveSessionName(
        agentSlug: String,
        workingDirectory: String,
        existingNames: Set<String>,
        customSuffix: String?,
        reattachExisting: Bool
    ) -> String {
        if reattachExisting {
            return TMuxSessionHelper.sessionName(
                agentSlug: agentSlug,
                workingDirectory: workingDirectory
            )
        }
        return TMuxSessionHelper.nextUniqueSessionName(
            agentSlug: agentSlug,
            workingDirectory: workingDirectory,
            existingNames: existingNames,
            customSuffix: customSuffix
        )
    }

    private var isTmuxKnownMissing: Bool {
        tmuxAvailability?.isInstalled == false
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
                    Button(isTmuxKnownMissing ? "Launch Anyway" : "Launch") {
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
            .task(id: selectedHost?.id) {
                guard let host = selectedHost else {
                    resetTmuxProbeState()
                    return
                }
                await probeTmuxStatus(for: host)
            }
            .onDisappear {
                tmuxInstallTask?.cancel()
                tmuxInstallTask = nil
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
            tmuxStatusSection
            agentSection
            directorySection
            optionsSection
            launchButtonSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var tmuxStatusSection: some View {
        if let host = selectedHost {
            if tmuxJustInstalled, tmuxAvailability?.isInstalled == true {
                Section {
                    tmuxConfirmedCard
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            } else if let availability = tmuxAvailability, !availability.isInstalled {
                Section {
                    tmuxMissingCard(host: host, availability: availability)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
    }

    private func tmuxMissingCard(
        host: Host,
        availability: TMuxSessionHelper.TMuxAvailability
    ) -> some View {
        let amber = palette.proBrandAmber
        let fill = amber.opacity(theme.isDark ? 0.14 : 0.10)
        let stroke = amber.opacity(0.45)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(amber)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("tmux is not installed on \(hostDisplayLabel(host))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Without tmux, your agent session will die if you close TermApp or lose connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if availability.packageManager != .unknown {
                if let tmuxInstallError {
                    Text(tmuxInstallError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tmuxRequiresInteractiveInstall ? amber : palette.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if tmuxRequiresInteractiveInstall,
                   let interactiveCmd = TMuxSessionHelper.installTmuxCommand(
                       packageManager: availability.packageManager,
                       isRoot: availability.isRoot,
                       interactive: true
                   ) {
                    VStack(spacing: 8) {
                        Button {
                            AppHaptics.impact(.light)
                            dismiss()
                            runTerminalCommand?(host, interactiveCmd)
                        } label: {
                            Label("Install in Terminal", systemImage: "terminal.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(amber)
                        .disabled(isInstallingTmux)
                    }
                } else {
                    Button {
                        startTmuxInstall(on: host, availability: availability)
                    } label: {
                        HStack(spacing: 8) {
                            if isInstallingTmux {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing tmux via \(availability.packageManager.displayName)…")
                                    .font(.subheadline.weight(.semibold))
                            } else {
                                Label(
                                    "Install tmux via \(availability.packageManager.displayName)",
                                    systemImage: "arrow.down.circle.fill"
                                )
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(amber)
                    .disabled(isInstallingTmux)
                }
            }
        }
        .padding(14)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
    }

    private var tmuxConfirmedCard: some View {
        let green = palette.healthy
        let fill = green.opacity(theme.isDark ? 0.14 : 0.10)
        let stroke = green.opacity(0.45)

        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(green)
                .accessibilityHidden(true)

            Text("tmux installed — your agent session will persist in the background.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
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
                    ProStatusLED(color: palette.healthy, size: 7)
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.healthy)
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
            : palette.cardFill
        let cardStroke = isSelected
            ? tint.opacity(0.75)
            : palette.borderSubtle

        return Button {
            AppHaptics.impact(.light)
            selectedAgentID = preset.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProSquircleIcon(
                        symbolName: AgentVisuals.agentSymbol(for: preset),
                        tint: tint,
                        size: .compact,
                        emphasis: isSelected ? .selected : .standard,
                        theme: theme
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text(preset.command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .frame(
                minWidth: dynamicTypeSize.isAccessibilitySize ? 140 : 118,
                maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : 118,
                alignment: .leading
            )
            .padding(10)
            .background(cardFill, in: RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous)
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
                    .foregroundStyle(palette.proBrandAmber)
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
                        .foregroundStyle(isFavoriteDirectory ? palette.proBrandAmber : .secondary)
                        .minTapTarget()
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
                    pathChipStrip(paths: favorites, icon: "star.fill", iconColor: palette.proBrandAmber)
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
                                .foregroundStyle(isSelected ? palette.proBrandAmber : iconColor)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? palette.proBrandAmber : .primary)
                        .background(
                            isSelected
                                ? palette.pillFill(for: palette.proBrandAmber)
                                : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? palette.proBrandAmber.opacity(0.55) : Color.clear,
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Session")
                    .foregroundStyle(.secondary)

                Picker("Session", selection: $reattachExisting) {
                    Text("New Session").tag(false)
                    Text("Reattach Existing").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: reattachExisting) { _, _ in
                    AppHaptics.impact(.light)
                }
            }
            .padding(.vertical, 2)

            if !reattachExisting {
                HStack(spacing: 10) {
                    Text("Session Label")
                        .foregroundStyle(.secondary)
                    TextField("optional (e.g. bugfix, ui)", text: $sessionLabel)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack(spacing: 10) {
                Text("Extra Flags")
                    .foregroundStyle(.secondary)
                TextField("e.g. --model sonnet", text: $extraArgs)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }

            AdaptiveKeyValueRow(spacing: 10) {
                Text("tmux Session")
                    .foregroundStyle(.secondary)
            } trailing: {
                Text(resolvedSessionName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("Session Options")
        } footer: {
            Text(optionsFooterText)
        }
    }

    private var optionsFooterText: String {
        if isTmuxKnownMissing {
            return "tmux is not installed, so this agent will run directly in your shell without background persistence."
        }
        if reattachExisting {
            return "Reattaches to the existing persistent tmux session for this agent and directory, or starts it if none exists."
        }
        return "Starts a new persistent tmux session so you can run multiple agents in parallel."
    }

    private var launchButtonSection: some View {
        Section {
            Button {
                launchSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AgentVisuals.agentSymbol(for: selectedAgent))
                    Text(isTmuxKnownMissing ? "Launch \(selectedAgent.name) Anyway" : "Launch \(selectedAgent.name)")
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
        } footer: {
            if isTmuxKnownMissing {
                Text("Running without tmux: closing TermApp or losing connection will terminate this agent.")
            }
        }
    }

    private func applyHostDefaults(for hostID: UUID) {
        resetTmuxProbeState()
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

    private func resetTmuxProbeState() {
        tmuxInstallTask?.cancel()
        tmuxInstallTask = nil
        tmuxAvailability = nil
        isInstallingTmux = false
        tmuxInstallError = nil
        tmuxRequiresInteractiveInstall = false
        tmuxJustInstalled = false
    }

    private func probeTmuxStatus(for host: Host) async {
        tmuxProbeGeneration += 1
        let generation = tmuxProbeGeneration
        let target = AgentHostTarget(host: host, sessionManager: sessionManager)

        do {
            let result = try await AgentAuthHelper.exec(
                TMuxSessionHelper.checkTmuxCommand(),
                on: target,
                timeout: .seconds(8)
            )
            guard !Task.isCancelled,
                  generation == tmuxProbeGeneration,
                  selectedHost?.id == host.id else {
                return
            }
            guard result.exitCode == 0,
                  result.stdout.contains("TMUX:INSTALLED") || result.stdout.contains("TMUX:MISSING") else {
                tmuxAvailability = nil
                return
            }
            let parsed = TMuxSessionHelper.parseTmuxAvailability(from: result.stdout)
            withAnimation(.easeInOut(duration: 0.2)) {
                tmuxAvailability = parsed
            }
        } catch {
            // Silently ignore auth, untrusted-host, or reachability errors on unconfigured hosts.
            guard !Task.isCancelled,
                  generation == tmuxProbeGeneration,
                  selectedHost?.id == host.id else {
                return
            }
            tmuxAvailability = nil
        }
    }

    private func startTmuxInstall(on host: Host, availability: TMuxSessionHelper.TMuxAvailability) {
        guard !isInstallingTmux else { return }
        tmuxInstallTask?.cancel()
        tmuxInstallTask = Task {
            await installTmux(on: host, availability: availability)
        }
    }

    private func installTmux(on host: Host, availability: TMuxSessionHelper.TMuxAvailability) async {
        guard let command = TMuxSessionHelper.installTmuxCommand(
            packageManager: availability.packageManager,
            isRoot: availability.isRoot,
            interactive: false
        ) else {
            return
        }

        AppHaptics.impact(.light)
        isInstallingTmux = true
        tmuxInstallError = nil
        tmuxRequiresInteractiveInstall = false

        let target = AgentHostTarget(host: host, sessionManager: sessionManager)
        let hostID = host.id

        do {
            let result = try await AgentAuthHelper.exec(
                command,
                on: target,
                timeout: .seconds(90)
            )
            guard !Task.isCancelled, selectedHost?.id == hostID else { return }

            if result.exitCode == 0 {
                let verifyResult = try await AgentAuthHelper.exec(
                    TMuxSessionHelper.checkTmuxCommand(),
                    on: target,
                    timeout: .seconds(8)
                )
                guard !Task.isCancelled, selectedHost?.id == hostID else { return }

                if verifyResult.exitCode == 0,
                   verifyResult.stdout.contains("TMUX:INSTALLED") || verifyResult.stdout.contains("TMUX:MISSING") {
                    let verified = TMuxSessionHelper.parseTmuxAvailability(from: verifyResult.stdout)
                    isInstallingTmux = false
                    if verified.isInstalled {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            tmuxAvailability = verified
                            tmuxJustInstalled = true
                            tmuxInstallError = nil
                            tmuxRequiresInteractiveInstall = false
                        }
                        AppHaptics.notify(.success)
                    } else {
                        tmuxAvailability = verified
                        tmuxInstallError = "Installation finished, but tmux was not found in PATH."
                        tmuxRequiresInteractiveInstall = TMuxSessionHelper.installTmuxCommand(
                            packageManager: availability.packageManager,
                            isRoot: availability.isRoot,
                            interactive: true
                        ) != nil
                        AppHaptics.notify(.warning)
                    }
                    return
                }

                isInstallingTmux = false
                let verifyDetail = conciseErrorLine(from: verifyResult.stderr)
                    ?? conciseErrorLine(from: verifyResult.stdout)
                if let verifyDetail {
                    tmuxInstallError = "Verification failed after tmux install: \(verifyDetail)"
                } else {
                    tmuxInstallError = "Verification failed after tmux install (exit code \(verifyResult.exitCode))."
                }
                tmuxRequiresInteractiveInstall = TMuxSessionHelper.installTmuxCommand(
                    packageManager: availability.packageManager,
                    isRoot: availability.isRoot,
                    interactive: true
                ) != nil
                AppHaptics.notify(.error)
                return
            }

            isInstallingTmux = false
            handleNonZeroInstallResult(result, availability: availability)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, selectedHost?.id == hostID else { return }
            isInstallingTmux = false
            tmuxInstallError = error.localizedDescription
            tmuxRequiresInteractiveInstall = TMuxSessionHelper.installTmuxCommand(
                packageManager: availability.packageManager,
                isRoot: availability.isRoot,
                interactive: true
            ) != nil
            AppHaptics.notify(.error)
        }
    }

    private func handleNonZeroInstallResult(
        _ result: SSHExecResult,
        availability: TMuxSessionHelper.TMuxAvailability
    ) {
        let combined = (result.stderr + "\n" + result.stdout).lowercased()
        let needsPassword = !availability.isRoot
            && availability.packageManager != .brew
            && (combined.contains("password")
                || combined.contains("no tty")
                || combined.contains("a terminal is required")
                || combined.contains("askpass"))

        if needsPassword {
            tmuxInstallError = "Administrator password required to install tmux."
        } else {
            tmuxInstallError = conciseErrorLine(from: result.stderr)
                ?? conciseErrorLine(from: result.stdout)
                ?? "Install failed (exit code \(result.exitCode))."
        }
        tmuxRequiresInteractiveInstall = TMuxSessionHelper.installTmuxCommand(
            packageManager: availability.packageManager,
            isRoot: availability.isRoot,
            interactive: true
        ) != nil
        AppHaptics.notify(.error)
    }

    private func conciseErrorLine(from output: String) -> String? {
        let lines = output
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let line = lines.last else { return nil }
        return line.count > 160 ? String(line.prefix(157)) + "…" : line
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
        let sessionName = resolvedSessionName
        let trimmedExtra = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)

        HostProjectStore.recordRecent(dir, for: host.id)
        HostProjectStore.setLastAgentID(agent.id, for: host.id)

        let command = TMuxSessionHelper.launchOrAttachCommand(
            agent: agent,
            workingDirectory: dir,
            extraArgs: trimmedExtra,
            sessionName: sessionName,
            forceNewSession: !reattachExisting
        )
        let context = AIAgentLaunchContext(
            agent: agent,
            sessionName: sessionName,
            workingDirectory: dir,
            hostID: host.id,
            isTmuxBacked: tmuxAvailability?.isInstalled ?? true
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
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var browsingPath: String
    @State private var resolvedPath: String = ""
    @State private var directories: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

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
                                .foregroundStyle(palette.proBrandAmber)
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
                                .foregroundStyle(palette.proBrandAmber)
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
                    .tint(palette.proBrandAmber)
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
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var name = ""
    @State private var command = ""
    @State private var defaultArgs = ""
    @State private var symbolName = "terminal"
    @State private var customPresets: [CustomAIAgentPreset] = HostProjectStore.customPresets()

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

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
                                    ProSquircleIcon(
                                        symbolName: symbol,
                                        tint: selected ? palette.proBrandAmber : palette.neutral,
                                        size: .row,
                                        emphasis: selected ? .selected : .standard,
                                        theme: theme
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
                    .tint(palette.proBrandAmber)
                    .disabled(!canSave)
                }

                if !customPresets.isEmpty {
                    Section("Saved Custom Presets") {
                        ForEach(customPresets) { preset in
                            HStack(spacing: 12) {
                                ProSquircleIcon(
                                    symbolName: preset.symbolName,
                                    tint: palette.neutral,
                                    size: .compact,
                                    theme: theme
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
