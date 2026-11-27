import SwiftUI
import SwiftData
import Store
import TermUI

/// DigitalOcean Droplet dashboard, 1-tap SSH launchpad, host sync, and droplet lifecycle sheet.
struct DigitalOceanView: View {
    private struct DropletDNSTarget: Identifiable {
        let id: Int
        let name: String
        let ip: String
    }

    let onOpenTokenSettings: () -> Void
    var showsInlineHeaderActions: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.connectHost) private var connectHost
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @Query(sort: \Host.label) private var savedHosts: [Host]

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    @State private var tokenInput = ""
    @State private var isConnectingToken = false
    @State private var tokenError: String?

    @State private var droplets: [DODroplet] = []
    @State private var accountKeys: [DOSSHKey] = []
    @State private var isLoading = false
    @State private var isSyncing = false
    @State private var busyDropletIDs: Set<Int> = []
    @State private var loadError: String?
    @State private var sshKeysError: String?
    @State private var actionError: String?
    @State private var statusBanner: String?

    @State private var showingCreateSheet = false
    @State private var confirmingDestroy: DODroplet?
    @State private var dnsTarget: DropletDNSTarget?

    var body: some View {
        VStack(spacing: 0) {
            if showsInlineHeaderActions {
                inlinePaneHeader
                Divider()
            }

            Group {
                if authState.hasDigitalOceanToken {
                    connectedContent
                } else {
                    CloudTokenOnboardingCard(
                        symbolName: "drop.fill",
                        tint: .blue,
                        title: "Connect DigitalOcean",
                        subtitle: "Browse your Droplets, 1-tap SSH, sync to Hosts, and spin up new cloud boxes.",
                        scopes: CloudScopeRequirement.digitalOcean,
                        placeholder: "Personal Access Token (dop_v1_…)",
                        buttonTitle: "Save Token",
                        tokenInput: $tokenInput,
                        isConnecting: isConnectingToken,
                        errorMessage: tokenError,
                        onConnect: {
                            Task { await connectWithToken() }
                        }
                    )
                }
            }
        }
        .toolbar {
            if !showsInlineHeaderActions && authState.hasDigitalOceanToken {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    syncDropletsButton
                    createDropletButton
                }
            }
        }
        .task(id: authState.hasDigitalOceanToken) {
            if authState.hasDigitalOceanToken {
                await loadDroplets(showSpinner: droplets.isEmpty)
            } else {
                droplets = []
                accountKeys = []
                loadError = nil
                sshKeysError = nil
                statusBanner = nil
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateDropletSheet(
                onCreated: { newDroplet in
                    if !droplets.contains(where: { $0.id == newDroplet.id }) {
                        droplets.insert(newDroplet, at: 0)
                    }
                    Task { await loadDroplets(showSpinner: false) }
                }
            )
            .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
            .tint(theme.accentColor)
        }
        .sheet(item: $dnsTarget) { target in
            QuickCloudflareDNSSheet(
                initialIP: target.ip,
                defaultSubdomain: Self.sanitizedSubdomain(from: target.name)
            ) { record in
                statusBanner = "Created A record \(record.name) → \(record.content)"
            }
            .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
            .tint(theme.accentColor)
        }
        .confirmationDialog(
            "Destroy Droplet?",
            isPresented: Binding(get: { confirmingDestroy != nil }, set: { if !$0 { confirmingDestroy = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDestroy
        ) { droplet in
            Button("Destroy Droplet", role: .destructive) {
                Task { await destroyDroplet(droplet) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { droplet in
            Text("This permanently destroys \(droplet.name) and removes its trusted SSH host key.")
        }
        .alert(
            "DigitalOcean Error",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var connectedContent: some View {
        List {
            if let statusBanner {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(statusBanner)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Button {
                            self.statusBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .minTapTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss notice")
                    }
                }
            }

            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)

                        HStack(spacing: 10) {
                            Button("Retry") {
                                AppHaptics.impact(.light)
                                Task { await loadDroplets(showSpinner: true) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Cloud Tokens") {
                                AppHaptics.impact(.light)
                                onOpenTokenSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let sshKeysError {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(sshKeysError)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Button {
                            self.sshKeysError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .minTapTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss SSH key warning")
                    }
                }
            }

            if !droplets.isEmpty {
                Section {
                    ForEach(droplets) { droplet in
                        dropletRow(droplet)
                    }
                } header: {
                    Text("Droplets")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadDroplets(showSpinner: false)
        }
        .overlay {
            if isLoading && droplets.isEmpty {
                ProgressView("Loading Droplets…")
            } else if !isLoading && droplets.isEmpty && loadError == nil {
                ContentUnavailableView {
                    Label("No Droplets", systemImage: "drop.fill")
                } description: {
                    Text("Create a DigitalOcean Droplet to connect with 1-tap SSH or sync it to Hosts.")
                } actions: {
                    Button("Create Droplet") {
                        AppHaptics.impact(.light)
                        showingCreateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var inlinePaneHeader: some View {
        let isConnected = authState.hasDigitalOceanToken
        return HStack(spacing: 10) {
            ProSquircleIcon(
                symbolName: "drop.fill",
                tint: .blue,
                size: .compact,
                theme: theme,
                statusLED: isConnected ? palette.healthy : nil,
                statusGlow: isConnected
            )

            Text("DigitalOcean")
                .font(.headline)

            Spacer(minLength: 8)

            if isConnected {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.healthy)
                }

                HStack(spacing: 2) {
                    syncDropletsButton
                        .minTapTarget()
                    createDropletButton
                        .minTapTarget()
                }
            } else {
                Text("Token Required")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isConnected ? 4 : 10)
        .frame(minHeight: 52)
        .background(.bar)
    }

    private var syncDropletsButton: some View {
        Button {
            AppHaptics.impact(.light)
            Task { await syncDropletsToHosts() }
        } label: {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Sync to Hosts", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(isSyncing || isLoading)
    }

    private var createDropletButton: some View {
        Button {
            AppHaptics.impact(.light)
            showingCreateSheet = true
        } label: {
            Label("Create Droplet", systemImage: "plus")
        }
    }

    private func dropletRow(_ droplet: DODroplet) -> some View {
        let isBusy = busyDropletIDs.contains(droplet.id)
        let hasIP = !(droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        return Button {
            connectToDroplet(droplet)
        } label: {
            HStack(spacing: 12) {
                dropletIcon(for: droplet)

                VStack(alignment: .leading, spacing: 3) {
                    Text(droplet.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text(droplet.publicIPv4 ?? "Pending IP")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(hasIP ? Color.secondary : Color.orange)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text(dropletMetadata(for: droplet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if hasIP {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.accentColor)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasIP || isBusy)
        .foregroundStyle(.primary)
        .accessibilityLabel("\(droplet.name), \(droplet.status), \(droplet.publicIPv4 ?? "Pending IP")")
        .contextMenu {
            if hasIP {
                Button("SSH Connect", systemImage: "terminal") {
                    connectToDroplet(droplet)
                }
            }

            if !droplet.isActive {
                Button("Power On", systemImage: "power") {
                    Task { await performAction(.powerOn, on: droplet) }
                }
            } else {
                Button("Reboot", systemImage: "arrow.clockwise") {
                    Task { await performAction(.reboot, on: droplet) }
                }
                Button("Power Off", systemImage: "poweroff") {
                    Task { await performAction(.powerOff, on: droplet) }
                }
            }

            if authState.hasCloudflareToken,
               let ip = droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                Button("Point Cloudflare DNS…", systemImage: "cloud") {
                    dnsTarget = DropletDNSTarget(id: droplet.id, name: droplet.name, ip: ip)
                }
            }

            Divider()

            Button("Destroy Droplet", systemImage: "trash", role: .destructive) {
                confirmingDestroy = droplet
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if hasIP {
                Button {
                    connectToDroplet(droplet)
                } label: {
                    Label("SSH", systemImage: "terminal")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmingDestroy = droplet
            } label: {
                Label("Destroy", systemImage: "trash")
            }

            if authState.hasCloudflareToken,
               let ip = droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                Button {
                    dnsTarget = DropletDNSTarget(id: droplet.id, name: droplet.name, ip: ip)
                } label: {
                    Label("DNS", systemImage: "cloud")
                }
                .tint(.orange)
            }
        }
    }

    private func dropletIcon(for droplet: DODroplet) -> some View {
        ProSquircleIcon(
            symbolName: "drop.fill",
            tint: .blue,
            size: .row,
            theme: theme,
            statusLED: ledColor(for: droplet.status),
            statusGlow: droplet.isActive
        )
    }

    private func ledColor(for status: String) -> Color {
        switch status.lowercased() {
        case "active":
            palette.healthy
        case "new":
            palette.warning
        default:
            palette.neutral
        }
    }

    private func dropletMetadata(for droplet: DODroplet) -> String {
        [droplet.specsSummary, droplet.imageName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func connectWithToken() async {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isConnectingToken = true
        tokenError = nil
        defer { isConnectingToken = false }

        do {
            let client = DigitalOceanClient(token: trimmed)
            let fetched = try await client.listDroplets()
            try authState.saveDigitalOceanToken(trimmed)
            tokenInput = ""
            droplets = fetched
            loadError = nil
            AppHaptics.notify(.success)
            do {
                accountKeys = try await client.listSSHKeys()
                sshKeysError = nil
            } catch is CancellationError {
                return
            } catch {
                sshKeysError = "Could not load DigitalOcean SSH keys: \(error.localizedDescription)"
            }
        } catch {
            tokenError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func loadDroplets(showSpinner: Bool) async {
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            return
        }
        if showSpinner {
            isLoading = true
        }
        loadError = nil
        defer { isLoading = false }

        let client = DigitalOceanClient(token: token)
        do {
            async let fetchedDroplets = client.listDroplets()
            async let fetchedKeys = client.listSSHKeys()
            droplets = try await fetchedDroplets
            do {
                accountKeys = try await fetchedKeys
                sshKeysError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sshKeysError = "Could not load DigitalOcean SSH keys: \(error.localizedDescription)"
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func syncDropletsToHosts() async {
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            return
        }
        isSyncing = true
        actionError = nil
        defer { isSyncing = false }

        let client = DigitalOceanClient(token: token)
        do {
            async let fetchedDroplets = client.listDroplets()
            async let fetchedKeys = client.listSSHKeys()
            let latestDroplets = try await fetchedDroplets
            let latestKeys: [DOSSHKey]
            do {
                latestKeys = try await fetchedKeys
                accountKeys = latestKeys
                sshKeysError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestKeys = accountKeys
                sshKeysError = "Could not load DigitalOcean SSH keys: \(error.localizedDescription)"
            }
            droplets = latestDroplets

            let result = try CloudHostSync.sync(
                droplets: latestDroplets,
                accountKeys: latestKeys,
                in: modelContext
            )
            statusBanner = result.summaryMessage
            AppHaptics.notify(.success)
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func connectToDroplet(_ droplet: DODroplet) {
        guard let ip = droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            return
        }
        AppHaptics.impact(.light)

        if let existing = savedHosts.first(where: { $0.source == "droplet" && $0.hostname == ip })
            ?? savedHosts.first(where: { $0.hostname == ip }) {
            connectHost?(existing)
            return
        }

        let auth = CloudHostSync.preferredSSHAuth(matchingAccountKeys: accountKeys)
        let ephemeral = Host(
            label: droplet.name,
            hostname: ip,
            port: 22,
            username: "root",
            authMethod: auth.authMethod,
            keyID: auth.keyID,
            tags: CloudHostSync.normalizedDropletTags(regionSlug: droplet.regionSlug),
            source: "droplet"
        )
        connectHost?(ephemeral)
    }

    private func performAction(_ action: DODropletActionType, on droplet: DODroplet) async {
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            return
        }
        busyDropletIDs.insert(droplet.id)
        defer { busyDropletIDs.remove(droplet.id) }

        do {
            let client = DigitalOceanClient(token: token)
            try await client.performAction(action, dropletID: droplet.id)
            AppHaptics.notify(.success)
            statusBanner = "\(actionDisplayTitle(action)) requested for \(droplet.name)."
            try await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await loadDroplets(showSpinner: false)
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func destroyDroplet(_ droplet: DODroplet) async {
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            return
        }
        busyDropletIDs.insert(droplet.id)
        defer { busyDropletIDs.remove(droplet.id) }

        do {
            let client = DigitalOceanClient(token: token)
            try await DigitalOceanClient.destroyDropletAndForgetHostKey(
                id: droplet.id,
                ipv4: droplet.publicIPv4,
                client: client
            )
            CloudHostSync.deleteSyncedHosts(forHostname: droplet.publicIPv4, in: modelContext)
            droplets.removeAll { $0.id == droplet.id }
            AppHaptics.notify(.warning)
            statusBanner = "Destroyed \(droplet.name) and removed its trusted host key."
        } catch {
            actionError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func actionDisplayTitle(_ action: DODropletActionType) -> String {
        switch action {
        case .powerOn: "Power on"
        case .powerOff: "Power off"
        case .shutdown: "Shutdown"
        case .reboot: "Reboot"
        }
    }

    private static func sanitizedSubdomain(from dropletName: String) -> String {
        let lowered = dropletName.lowercased()
        let allowed = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-") ? ch : "-"
        }
        let collapsed = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "droplet" : collapsed
    }
}

/// Sheet for provisioning a new DigitalOcean Droplet with optional Cloudflare DNS record creation.
struct CreateDropletSheet: View {
    let onCreated: (DODroplet) -> Void

    @Environment(\.dismiss) private var dismiss
    private var authState: CloudAuthState { CloudAuthState.shared }

    @State private var name = ""
    @State private var regions: [DORegion] = []
    @State private var sizes: [DOSize] = []
    @State private var images: [DOImage] = []
    @State private var accountKeys: [DOSSHKey] = []
    @State private var localKeys: [StoredKey] = []

    @State private var selectedRegionSlug = ""
    @State private var selectedSizeSlug = ""
    @State private var selectedImageID: Int?
    @State private var selectedKeyIDs: Set<Int> = []

    @State private var pointDNS = false
    @State private var cfZones: [CFZone] = []
    @State private var selectedZoneID = ""
    @State private var subdomain = ""
    @State private var dnsProxied = false
    @State private var isLoadingZones = false
    @State private var zonesError: String?

    @State private var isLoadingOptions = true
    @State private var loadError: String?
    @State private var sshKeysError: String?
    @State private var isRetryingKeys = false
    @State private var isCreating = false
    @State private var pushingLocalKeyID: UUID?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var createTask: Task<Void, Never>?
    @State private var dnsWaitTask: Task<Void, any Error>?
    @State private var createdDropletForFollowUp: DODroplet?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedImage: DOImage? {
        images.first(where: { $0.id == selectedImageID })
    }

    private var selectedZone: CFZone? {
        cfZones.first(where: { $0.id == selectedZoneID })
    }

    private var unpushedLocalKeys: [StoredKey] {
        let accountPublicKeys = Set(
            accountKeys
                .map { CloudHostSync.normalizePublicKey($0.publicKey) }
                .filter { !$0.isEmpty }
        )
        return localKeys.filter {
            !$0.publicKey.isEmpty && !accountPublicKeys.contains(CloudHostSync.normalizePublicKey($0.publicKey))
        }
    }

    private var canCreate: Bool {
        createdDropletForFollowUp == nil
            && !isLoadingOptions
            && !isCreating
            && !trimmedName.isEmpty
            && !trimmedName.contains(where: \.isWhitespace)
            && !selectedRegionSlug.isEmpty
            && !selectedSizeSlug.isEmpty
            && selectedImage != nil
            && (!pointDNS || !selectedZoneID.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoadingOptions {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading regions, sizes, images, and SSH keys…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else if let loadError {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await loadOptions() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    configurationSections
                    sshKeysSection
                    if authState.hasCloudflareToken {
                        cloudflareDNSSection
                    }
                }

                if let statusMessage {
                    Section {
                        HStack(spacing: 10) {
                            if dnsWaitTask != nil {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Text(statusMessage)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if dnsWaitTask != nil {
                            Button("Skip DNS Wait & Finish") {
                                finishWithoutWaitingForDNS()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Create Droplet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdDropletForFollowUp == nil ? "Cancel" : "Done") {
                        createTask?.cancel()
                        createTask = nil
                        dnsWaitTask?.cancel()
                        dnsWaitTask = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        AppHaptics.impact(.light)
                        createTask?.cancel()
                        createTask = Task { await createDroplet() }
                    } label: {
                        if isCreating && dnsWaitTask == nil {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task {
                await loadOptions()
            }
            .onDisappear {
                createTask?.cancel()
                createTask = nil
                dnsWaitTask?.cancel()
                dnsWaitTask = nil
            }
            .onChange(of: pointDNS) { _, enabled in
                if enabled && cfZones.isEmpty && !isLoadingZones {
                    Task { await loadCloudflareZones() }
                }
            }
        }
    }

    @ViewBuilder
    private var configurationSections: some View {
        Section("Droplet") {
            TextField("Hostname (e.g. dev-box-1)", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(isCreating)

            Picker("Region", selection: $selectedRegionSlug) {
                ForEach(regions) { region in
                    Text("\(region.name) (\(region.slug))").tag(region.slug)
                }
            }
            .disabled(isCreating)

            Picker("Size", selection: $selectedSizeSlug) {
                ForEach(sizes) { size in
                    Text(sizeLabel(for: size)).tag(size.slug)
                }
            }
            .disabled(isCreating)

            Picker("OS Image", selection: $selectedImageID) {
                ForEach(images) { image in
                    Text(imageLabel(for: image)).tag(Int?.some(image.id))
                }
            }
            .disabled(isCreating)
        }
    }

    private var sshKeysSection: some View {
        Section {
            if let sshKeysError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Could not load account SSH keys: \(sshKeysError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await retrySSHKeys() }
                    } label: {
                        if isRetryingKeys {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Retry SSH Keys")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCreating || isRetryingKeys)
                }
            } else if accountKeys.isEmpty {
                Text("No SSH keys registered on your DigitalOcean account yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accountKeys) { key in
                    let isSelected = selectedKeyIDs.contains(key.id)
                    Button {
                        AppHaptics.impact(.light)
                        if isSelected {
                            selectedKeyIDs.remove(key.id)
                        } else {
                            selectedKeyIDs.insert(key.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(key.fingerprint)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                }
            }

            if !unpushedLocalKeys.isEmpty {
                ForEach(unpushedLocalKeys) { localKey in
                    Button {
                        AppHaptics.impact(.light)
                        Task { await pushLocalKey(localKey) }
                    } label: {
                        HStack(spacing: 10) {
                            Label("Push \"\(localKey.name)\" to DigitalOcean", systemImage: "icloud.and.arrow.up")
                            Spacer()
                            if pushingLocalKeyID == localKey.id {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(pushingLocalKeyID != nil || isCreating)
                }
            } else if sshKeysError == nil && accountKeys.isEmpty && localKeys.isEmpty {
                Text("Tip: Generate an SSH key in the Keys tab to avoid emailed root passwords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("SSH Keys")
        } footer: {
            Text("Selected SSH keys are injected into root@droplet on first boot.")
        }
    }

    private var cloudflareDNSSection: some View {
        Section {
            Toggle("Point Cloudflare DNS", isOn: $pointDNS)
                .disabled(isCreating)

            if pointDNS {
                if isLoadingZones {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading Cloudflare zones…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let zonesError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(zonesError)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry Zones") {
                            Task { await loadCloudflareZones() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if cfZones.isEmpty {
                    Text("No Cloudflare DNS zones accessible with this token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Zone", selection: $selectedZoneID) {
                        ForEach(cfZones) { zone in
                            Text(zone.name).tag(zone.id)
                        }
                    }
                    .disabled(isCreating)

                    TextField("Subdomain (e.g. dev or @)", text: $subdomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isCreating)

                    if let zone = selectedZone {
                        let resolved = CloudflareDNSFormatter.resolvedRecordName(
                            input: subdomain.isEmpty ? trimmedName : subdomain,
                            zoneName: zone.name
                        )
                        HStack {
                            Text("A Record")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(resolved)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }

                    Toggle("Proxy through Cloudflare", isOn: $dnsProxied)
                        .disabled(isCreating)
                }
            }
        } header: {
            Text("Cloudflare DNS (Optional)")
        } footer: {
            if pointDNS {
                Text("Creates an A record automatically once DigitalOcean assigns the Droplet's IPv4 address.")
            }
        }
    }

    private func loadOptions() async {
        guard let token = DigitalOceanTokenStore.read() else {
            loadError = DOError.missingToken.localizedDescription
            isLoadingOptions = false
            return
        }
        isLoadingOptions = true
        loadError = nil
        localKeys = (try? KeyStore().list()) ?? []

        let client = DigitalOceanClient(token: token)
        do {
            async let fetchedRegions = client.listRegions()
            async let fetchedSizes = client.listSizes()
            async let fetchedImages = client.listDistributionImages()
            async let fetchedKeys = client.listSSHKeys()

            let loadedRegions = try await fetchedRegions
            let loadedSizes = try await fetchedSizes
            let loadedImages = Self.prioritizedImages(try await fetchedImages)
            let loadedKeys: [DOSSHKey]
            do {
                loadedKeys = try await fetchedKeys
                sshKeysError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                loadedKeys = []
                sshKeysError = error.localizedDescription
            }

            regions = loadedRegions
            sizes = loadedSizes
            images = loadedImages
            accountKeys = loadedKeys

            if selectedRegionSlug.isEmpty {
                selectedRegionSlug = loadedRegions.first(where: { $0.slug == "nyc3" })?.slug
                    ?? loadedRegions.first?.slug
                    ?? ""
            }
            if selectedSizeSlug.isEmpty {
                selectedSizeSlug = loadedSizes.first?.slug ?? ""
            }
            if selectedImageID == nil {
                selectedImageID = loadedImages.first?.id
            }

            applyDefaultSelectedKeys(from: loadedKeys)

            isLoadingOptions = false
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
            isLoadingOptions = false
        }
    }

    private func retrySSHKeys() async {
        guard let token = DigitalOceanTokenStore.read() else { return }
        isRetryingKeys = true
        defer { isRetryingKeys = false }

        do {
            let loadedKeys = try await DigitalOceanClient(token: token).listSSHKeys()
            accountKeys = loadedKeys
            sshKeysError = nil
            applyDefaultSelectedKeys(from: loadedKeys)
        } catch is CancellationError {
            return
        } catch {
            sshKeysError = error.localizedDescription
        }
    }

    private func applyDefaultSelectedKeys(from loadedKeys: [DOSSHKey]) {
        guard selectedKeyIDs.isEmpty else { return }
        let localNormalized = Set(localKeys.map { CloudHostSync.normalizePublicKey($0.publicKey) })
        let matchingAccountKeys = loadedKeys.filter {
            localNormalized.contains(CloudHostSync.normalizePublicKey($0.publicKey))
        }
        if !matchingAccountKeys.isEmpty {
            selectedKeyIDs = Set(matchingAccountKeys.map(\.id))
        } else if let firstKey = loadedKeys.first {
            selectedKeyIDs = [firstKey.id]
        }
    }

    private func loadCloudflareZones() async {
        guard let cfToken = CloudflareTokenStore.read() else { return }
        isLoadingZones = true
        zonesError = nil
        defer { isLoadingZones = false }

        do {
            let loaded = try await CloudflareClient(token: cfToken).listZones()
            cfZones = loaded
            if selectedZoneID.isEmpty {
                selectedZoneID = loaded.first?.id ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            zonesError = error.localizedDescription
        }
    }

    private func pushLocalKey(_ localKey: StoredKey) async {
        guard let token = DigitalOceanTokenStore.read() else { return }
        pushingLocalKeyID = localKey.id
        errorMessage = nil
        defer { pushingLocalKeyID = nil }

        do {
            let pushed = try await DigitalOceanClient(token: token).createSSHKey(
                name: localKey.name,
                publicKey: localKey.publicKey
            )
            if !accountKeys.contains(where: { $0.id == pushed.id }) {
                accountKeys.append(pushed)
            }
            selectedKeyIDs.insert(pushed.id)
            AppHaptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func createDroplet() async {
        guard let token = DigitalOceanTokenStore.read(), let selectedImage else { return }
        isCreating = true
        errorMessage = nil
        statusMessage = nil

        let imageIdentifier = selectedImage.slug ?? String(selectedImage.id)
        let request = DOCreateDropletRequest(
            name: trimmedName,
            region: selectedRegionSlug,
            size: selectedSizeSlug,
            image: imageIdentifier,
            sshKeys: Array(selectedKeyIDs)
        )

        let doClient = DigitalOceanClient(token: token)
        defer { createTask = nil }
        do {
            let created = try await doClient.createDroplet(request)
            createdDropletForFollowUp = created
            onCreated(created)
            guard !Task.isCancelled else {
                isCreating = false
                return
            }
            AppHaptics.notify(.success)

            if pointDNS, let zone = selectedZone, let cfToken = CloudflareTokenStore.read() {
                let effectiveInput = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? trimmedName
                    : subdomain
                let fqdn = CloudflareDNSFormatter.resolvedRecordName(input: effectiveInput, zoneName: zone.name)
                await assignDNSAfterDropletCreate(
                    droplet: created,
                    doClient: doClient,
                    cfClient: CloudflareClient(token: cfToken),
                    zone: zone,
                    fqdn: fqdn,
                    proxied: dnsProxied
                )
            } else {
                isCreating = false
                dismiss()
            }
        } catch is CancellationError {
            isCreating = false
        } catch {
            isCreating = false
            errorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func assignDNSAfterDropletCreate(
        droplet: DODroplet,
        doClient: DigitalOceanClient,
        cfClient: CloudflareClient,
        zone: CFZone,
        fqdn: String,
        proxied: Bool
    ) async {
        if let ip = droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
            do {
                _ = try await cfClient.createDNSRecord(
                    zoneID: zone.id,
                    record: CFDNSRecordInput(type: "A", name: fqdn, content: ip, proxied: proxied)
                )
                isCreating = false
                dismiss()
            } catch is CancellationError {
                isCreating = false
            } catch {
                isCreating = false
                errorMessage = "Droplet created, but DNS creation failed: \(error.localizedDescription)"
            }
            return
        }

        guard !Task.isCancelled else {
            isCreating = false
            return
        }

        statusMessage = "Droplet created! Waiting for public IPv4 to create \(fqdn)…"
        let waitTask = Task { @MainActor in
            var latestDroplet = droplet
            for _ in 0..<15 {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                let list = try await doClient.listDroplets()
                try Task.checkCancellation()
                if let match = list.first(where: { $0.id == droplet.id }) {
                    latestDroplet = match
                    createdDropletForFollowUp = match
                    if let ip = match.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
                        _ = try await cfClient.createDNSRecord(
                            zoneID: zone.id,
                            record: CFDNSRecordInput(type: "A", name: fqdn, content: ip, proxied: proxied)
                        )
                        AppHaptics.notify(.success)
                        dnsWaitTask = nil
                        isCreating = false
                        onCreated(latestDroplet)
                        dismiss()
                        return
                    }
                }
            }
            dnsWaitTask = nil
            isCreating = false
            statusMessage = "Droplet created. IPv4 is still provisioning — use \"Point Cloudflare DNS…\" from the Droplet menu once active."
            onCreated(latestDroplet)
        }
        dnsWaitTask = waitTask

        do {
            try await waitTask.value
        } catch is CancellationError {
            return
        } catch {
            dnsWaitTask = nil
            isCreating = false
            errorMessage = "Droplet created, but DNS follow-up failed: \(error.localizedDescription)"
        }
    }

    private func finishWithoutWaitingForDNS() {
        dnsWaitTask?.cancel()
        dnsWaitTask = nil
        isCreating = false
        if let created = createdDropletForFollowUp {
            onCreated(created)
        }
        dismiss()
    }

    private func sizeLabel(for size: DOSize) -> String {
        let priceText: String
        if size.priceMonthly.rounded() == size.priceMonthly {
            priceText = "$\(Int(size.priceMonthly))/mo"
        } else {
            priceText = String(format: "$%.2f/mo", locale: Locale(identifier: "en_US_POSIX"), size.priceMonthly)
        }
        let cpuText = size.vcpus == 1 ? "1 vCPU" : "\(size.vcpus) vCPUs"
        let memText = size.memory < 1024 ? "\(size.memory) MB" : "\(size.memory / 1024) GB"
        return "\(priceText) · \(cpuText) · \(memText) · \(size.disk) GB"
    }

    private func imageLabel(for image: DOImage) -> String {
        if image.name.lowercased().hasPrefix(image.distribution.lowercased()) {
            return image.name
        }
        return "\(image.distribution) \(image.name)"
    }

    private static func prioritizedImages(_ images: [DOImage]) -> [DOImage] {
        images.sorted { lhs, rhs in
            let lRank = imagePriorityRank(lhs)
            let rRank = imagePriorityRank(rhs)
            if lRank != rRank { return lRank < rRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        }
    }

    private static func imagePriorityRank(_ image: DOImage) -> Int {
        let distro = image.distribution.lowercased()
        let name = image.name.lowercased()
        if distro == "ubuntu" && name.contains("lts") { return 0 }
        if distro == "debian" { return 1 }
        if distro == "ubuntu" { return 2 }
        return 3
    }
}
