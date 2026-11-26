import SwiftUI
import SwiftData
import UIKit
import Store
import TermUI

/// Cloudflare DNS zones & records plus Zero Trust Tunnels inspector.
struct CloudflareView: View {
    private struct AccountTunnel: Identifiable, Hashable {
        let account: CFAccount
        let tunnel: CFTunnel

        var id: String { "\(account.id):\(tunnel.id)" }
    }

    let onOpenTokenSettings: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    @State private var tokenInput = ""
    @State private var isConnectingToken = false
    @State private var tokenError: String?

    @State private var zones: [CFZone] = []
    @State private var tunnels: [AccountTunnel] = []
    @State private var isLoading = false
    @State private var zonesError: String?
    @State private var tunnelsError: String?

    var body: some View {
        Group {
            if authState.hasCloudflareToken {
                connectedContent
            } else {
                CloudTokenOnboardingCard(
                    symbolName: "cloud.fill",
                    tint: .orange,
                    title: "Connect Cloudflare",
                    subtitle: "Manage DNS zone records with 1-tap Droplet IPs and inspect Zero Trust Tunnels.",
                    scopes: CloudScopeRequirement.cloudflare,
                    placeholder: "Cloudflare API Token",
                    buttonTitle: "Verify & Connect",
                    tokenInput: $tokenInput,
                    isConnecting: isConnectingToken,
                    errorMessage: tokenError,
                    onConnect: {
                        Task { await connectWithToken() }
                    }
                )
            }
        }
        .task(id: authState.hasCloudflareToken) {
            if authState.hasCloudflareToken {
                await loadResources(showSpinner: zones.isEmpty && tunnels.isEmpty)
            } else {
                zones = []
                tunnels = []
                zonesError = nil
                tunnelsError = nil
            }
        }
    }

    private var connectedContent: some View {
        List {
            Section("DNS Zones") {
                if let zonesError {
                    errorSectionRow(message: zonesError)
                } else if zones.isEmpty && !isLoading {
                    Text("No DNS zones accessible with this token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(zones) { zone in
                        NavigationLink {
                            CloudflareDNSRecordsView(zone: zone)
                        } label: {
                            zoneRow(zone)
                        }
                    }
                }
            }

            Section("Zero Trust Tunnels") {
                if let tunnelsError {
                    errorSectionRow(message: tunnelsError)
                } else if tunnels.isEmpty && !isLoading {
                    Text("No Zero Trust Tunnels found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tunnels) { item in
                        NavigationLink {
                            CloudflareTunnelDetailView(account: item.account, tunnel: item.tunnel)
                        } label: {
                            tunnelRow(item.tunnel)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadResources(showSpinner: false)
        }
        .overlay {
            if isLoading && zones.isEmpty && tunnels.isEmpty {
                ProgressView("Loading Cloudflare…")
            }
        }
    }

    private func zoneRow(_ zone: CFZone) -> some View {
        let isActive = zone.status.lowercased() == "active"
        let statusColor = isActive ? palette.healthy : palette.warning

        return HStack(spacing: 12) {
            ProSquircleIcon(
                symbolName: "globe",
                tint: .orange,
                size: .row,
                theme: theme,
                statusLED: statusColor,
                statusGlow: isActive
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(zone.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                HStack(spacing: 6) {
                    ProStatusLED(
                        color: statusColor,
                        size: 7,
                        glow: false
                    )
                    Text(zone.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func tunnelRow(_ tunnel: CFTunnel) -> some View {
        let connectorText = tunnel.connectionCount == 1 ? "1 connector" : "\(tunnel.connectionCount) connectors"
        let ledColor = Self.tunnelLEDColor(for: tunnel.status, palette: palette)

        return HStack(spacing: 12) {
            ProSquircleIcon(
                symbolName: "point.3.connected.trianglepath.dotted",
                tint: .teal,
                size: .row,
                theme: theme,
                statusLED: ledColor,
                statusGlow: tunnel.status == .healthy
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                Text("\(tunnel.status.rawValue.capitalized) · \(connectorText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .padding(.vertical, 3)
    }

    private func errorSectionRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)

            HStack(spacing: 10) {
                Button("Retry") {
                    AppHaptics.impact(.light)
                    Task { await loadResources(showSpinner: true) }
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

    private func connectWithToken() async {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isConnectingToken = true
        tokenError = nil
        defer { isConnectingToken = false }

        do {
            let client = CloudflareClient(token: trimmed)
            let isValid = try await client.verifyToken()
            guard isValid else {
                tokenError = "Cloudflare token is not active."
                AppHaptics.notify(.error)
                return
            }
            try authState.saveCloudflareToken(trimmed)
            tokenInput = ""
            AppHaptics.notify(.success)
        } catch {
            tokenError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func loadResources(showSpinner: Bool) async {
        guard let token = CloudflareTokenStore.read() else {
            authState.refresh()
            return
        }
        if showSpinner {
            isLoading = true
        }
        defer { isLoading = false }

        let client = CloudflareClient(token: token)

        async let zonesResult: Result<[CFZone], Error> = {
            do {
                return .success(try await client.listZones())
            } catch {
                return .failure(error)
            }
        }()

        async let tunnelsResult: Result<[AccountTunnel], Error> = {
            do {
                let accounts = try await client.listAccounts()
                let items = try await withThrowingTaskGroup(of: [AccountTunnel].self) { group in
                    for account in accounts {
                        group.addTask {
                            let list = try await client.listTunnels(accountID: account.id)
                            return list.map { AccountTunnel(account: account, tunnel: $0) }
                        }
                    }
                    var combined: [AccountTunnel] = []
                    for try await partial in group {
                        combined.append(contentsOf: partial)
                    }
                    return combined
                }
                let sorted = items.sorted {
                    $0.tunnel.name.localizedCaseInsensitiveCompare($1.tunnel.name) == .orderedAscending
                }
                return .success(sorted)
            } catch {
                return .failure(error)
            }
        }()

        let loadedZones = await zonesResult
        let loadedTunnels = await tunnelsResult
        guard !Task.isCancelled else { return }

        switch loadedZones {
        case .success(let z):
            zones = z
            zonesError = nil
        case .failure(let error):
            zonesError = error.localizedDescription
        }

        switch loadedTunnels {
        case .success(let t):
            tunnels = t
            tunnelsError = nil
        case .failure(let error):
            tunnelsError = error.localizedDescription
        }
    }

    static func tunnelLEDColor(
        for status: CFTunnelStatus,
        palette: ProDesign.Palette = ProDesign.Palette()
    ) -> Color {
        switch status {
        case .healthy: palette.healthy
        case .degraded: palette.warning
        case .inactive, .down: palette.critical
        case .unknown: palette.neutral
        }
    }
}

/// Lists and manages Cloudflare DNS records within a zone.
struct CloudflareDNSRecordsView: View {
    private enum EditorTarget: Identifiable {
        case create
        case edit(CFDNSRecord)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let record): record.id
            }
        }

        var existing: CFDNSRecord? {
            switch self {
            case .create: nil
            case .edit(let record): record
            }
        }
    }

    let zone: CFZone

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var records: [CFDNSRecord] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var deleteError: String?
    @State private var editorTarget: EditorTarget?
    @State private var confirmingDelete: CFDNSRecord?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var filteredRecords: [CFDNSRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
                || $0.type.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await loadRecords(showSpinner: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            ForEach(filteredRecords) { record in
                Button {
                    AppHaptics.impact(.light)
                    editorTarget = .edit(record)
                } label: {
                    recordRow(record)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        confirmingDelete = record
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Filter by name, type, or content")
        .navigationTitle(zone.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.impact(.light)
                    editorTarget = .create
                } label: {
                    Label("New Record", systemImage: "plus")
                }
            }
        }
        .refreshable {
            await loadRecords(showSpinner: false)
        }
        .overlay {
            if isLoading && records.isEmpty {
                ProgressView("Loading DNS Records…")
            } else if !isLoading && filteredRecords.isEmpty && loadError == nil {
                ContentUnavailableView(
                    records.isEmpty ? "No DNS Records" : "No Matching Records",
                    systemImage: records.isEmpty ? "network" : "magnifyingglass",
                    description: Text(records.isEmpty ? "Tap + to add a DNS record." : "Try clearing the search filter.")
                )
            }
        }
        .task {
            await loadRecords(showSpinner: records.isEmpty)
        }
        .sheet(item: $editorTarget) { target in
            DNSRecordEditorSheet(zone: zone, existing: target.existing) { saved in
                upsertLocalRecord(saved)
            }
            .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
            .tint(theme.accentColor)
        }
        .confirmationDialog(
            "Delete DNS record?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { record in
            Button("Delete \(record.type) Record", role: .destructive) {
                Task { await deleteRecord(record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Delete \(record.type) record \"\(record.name)\" pointing to \(record.content)?")
        }
        .alert(
            "DNS Error",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func recordRow(_ record: CFDNSRecord) -> some View {
        HStack(spacing: 12) {
            Text(record.type)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: ProDesign.Radius.tagChip, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                Text(record.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }

            Spacer(minLength: 8)

            if record.proxied {
                Image(systemName: "cloud.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Proxied")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func loadRecords(showSpinner: Bool) async {
        guard let token = CloudflareTokenStore.read() else { return }
        if showSpinner {
            isLoading = true
        }
        loadError = nil
        defer { isLoading = false }

        do {
            records = try await CloudflareClient(token: token).listDNSRecords(zoneID: zone.id)
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func upsertLocalRecord(_ record: CFDNSRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }

    private func deleteRecord(_ record: CFDNSRecord) async {
        guard let token = CloudflareTokenStore.read() else { return }
        do {
            try await CloudflareClient(token: token).deleteDNSRecord(zoneID: zone.id, recordID: record.id)
            records.removeAll { $0.id == record.id }
            AppHaptics.notify(.warning)
        } catch {
            deleteError = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }
}

/// Sheet for creating or editing a Cloudflare DNS record, with 1-tap Host / Droplet IP picker.
struct DNSRecordEditorSheet: View {
    private static let baseTypes = ["A", "AAAA", "CNAME", "TXT"]

    let zone: CFZone
    let existing: CFDNSRecord?
    let onSaved: (CFDNSRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var type = "A"
    @State private var name = ""
    @State private var content = ""
    @State private var proxied = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingTargetPicker = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var availableTypes: [String] {
        if let existing, !Self.baseTypes.contains(existing.type) {
            return Self.baseTypes + [existing.type]
        }
        return Self.baseTypes
    }

    private var supportsProxy: Bool {
        ["A", "AAAA", "CNAME"].contains(type)
    }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Record") {
                    Picker("Type", selection: $type) {
                        ForEach(availableTypes, id: \.self) { recordType in
                            Text(recordType).tag(recordType)
                        }
                    }

                    TextField("Name (e.g. @ or ssh)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(contentPlaceholder, text: $content)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    Button {
                        AppHaptics.impact(.light)
                        showingTargetPicker = true
                    } label: {
                        Label("Pick from Hosts / Droplets", systemImage: "server.rack")
                    }
                }

                if supportsProxy {
                    Section {
                        Toggle("Proxy through Cloudflare", isOn: $proxied)
                    } footer: {
                        Text("Disable proxy (DNS-only) for direct SSH connections to your server IP.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New DNS Record" : "Edit DNS Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        AppHaptics.impact(.light)
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let existing {
                    type = existing.type
                    name = existing.name
                    content = existing.content
                    proxied = existing.proxied
                }
            }
            .sheet(isPresented: $showingTargetPicker) {
                DNSTargetPickerSheet { selectedTarget in
                    content = selectedTarget
                }
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
            }
        }
    }

    private var contentPlaceholder: String {
        switch type {
        case "A": "IPv4 address (e.g. 203.0.113.10)"
        case "AAAA": "IPv6 address"
        case "CNAME": "Target hostname"
        case "TXT": "Text value"
        default: "Record content"
        }
    }

    private func save() async {
        guard let token = CloudflareTokenStore.read() else {
            errorMessage = CloudflareError.missingToken.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let resolvedName = CloudflareDNSFormatter.resolvedRecordName(input: name, zoneName: zone.name)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = CFDNSRecordInput(
            type: type,
            name: resolvedName,
            content: trimmedContent,
            proxied: supportsProxy ? proxied : false
        )

        let client = CloudflareClient(token: token)
        do {
            let saved: CFDNSRecord
            if let existing {
                saved = try await client.updateDNSRecord(zoneID: zone.id, recordID: existing.id, record: input)
            } else {
                saved = try await client.createDNSRecord(zoneID: zone.id, record: input)
            }
            AppHaptics.notify(.success)
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }
}

/// Picker sheet populating DNS record content from live DigitalOcean Droplets or saved SwiftData Hosts.
private struct DNSTargetPickerSheet: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Host.label) private var savedHosts: [Host]
    private var authState: CloudAuthState { CloudAuthState.shared }

    @State private var droplets: [DODroplet] = []
    @State private var isLoadingDroplets = false
    @State private var dropletError: String?

    var body: some View {
        NavigationStack {
            List {
                if authState.hasDigitalOceanToken {
                    Section("DigitalOcean Droplets") {
                        if isLoadingDroplets {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading Droplets…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let dropletError {
                            Text(dropletError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            let withIP = droplets.filter {
                                !($0.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                            }
                            if withIP.isEmpty {
                                Text("No Droplets with public IPv4 addresses.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(withIP) { droplet in
                                    if let ip = droplet.publicIPv4 {
                                        Button {
                                            AppHaptics.impact(.light)
                                            onSelect(ip)
                                            dismiss()
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(droplet.name)
                                                        .font(.headline)
                                                    Text(droplet.specsSummary)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Text(ip)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Saved Hosts") {
                    let validHosts = savedHosts.filter {
                        !$0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if validHosts.isEmpty {
                        Text("No saved hosts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(validHosts) { host in
                            Button {
                                AppHaptics.impact(.light)
                                onSelect(host.hostname)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(host.label.isEmpty ? host.hostname : host.label)
                                        .font(.headline)
                                    Spacer()
                                    Text(host.hostname)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pick Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard authState.hasDigitalOceanToken, let token = DigitalOceanTokenStore.read() else { return }
                isLoadingDroplets = true
                defer { isLoadingDroplets = false }
                do {
                    droplets = try await DigitalOceanClient(token: token).listDroplets()
                } catch is CancellationError {
                    return
                } catch {
                    dropletError = error.localizedDescription
                }
            }
        }
    }
}

/// Quick sheet launched from a DigitalOcean Droplet to point a Cloudflare A record at its IPv4.
struct QuickCloudflareDNSSheet: View {
    let initialIP: String
    let defaultSubdomain: String
    let onCreated: (CFDNSRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var zones: [CFZone] = []
    @State private var selectedZoneID = ""
    @State private var subdomain = ""
    @State private var proxied = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var selectedZone: CFZone? {
        zones.first(where: { $0.id == selectedZoneID })
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading Cloudflare zones…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if zones.isEmpty {
                    Section {
                        Text(errorMessage ?? "No Cloudflare DNS zones found.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("A Record") {
                        Picker("Zone", selection: $selectedZoneID) {
                            ForEach(zones) { zone in
                                Text(zone.name).tag(zone.id)
                            }
                        }

                        TextField("Subdomain (e.g. @ or dev)", text: $subdomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        HStack {
                            Text("Target IPv4")
                            Spacer()
                            Text(initialIP)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if let zone = selectedZone {
                            HStack {
                                Text("FQDN")
                                Spacer()
                                Text(CloudflareDNSFormatter.resolvedRecordName(input: subdomain, zoneName: zone.name))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle("Proxy through Cloudflare", isOn: $proxied)
                    }
                }

                if let errorMessage, !zones.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Point Cloudflare DNS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        AppHaptics.impact(.light)
                        Task { await createRecord() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isLoading || isSaving || selectedZone == nil)
                }
            }
            .onAppear {
                if subdomain.isEmpty {
                    subdomain = defaultSubdomain
                }
            }
            .task {
                await loadZones()
            }
        }
    }

    private func loadZones() async {
        guard let token = CloudflareTokenStore.read() else {
            errorMessage = CloudflareError.missingToken.localizedDescription
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await CloudflareClient(token: token).listZones()
            zones = loaded
            if selectedZoneID.isEmpty {
                selectedZoneID = loaded.first?.id ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createRecord() async {
        guard let token = CloudflareTokenStore.read(), let zone = selectedZone else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let fqdn = CloudflareDNSFormatter.resolvedRecordName(input: subdomain, zoneName: zone.name)
        let input = CFDNSRecordInput(type: "A", name: fqdn, content: initialIP, proxied: proxied)

        do {
            let created = try await CloudflareClient(token: token).createDNSRecord(zoneID: zone.id, record: input)
            AppHaptics.notify(.success)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }
}

/// Detail screen displaying a Zero Trust Tunnel's status and exposed ingress rules.
struct CloudflareTunnelDetailView: View {
    let account: CFAccount
    let tunnel: CFTunnel

    @Environment(\.openURL) private var openURL
    @State private var rules: [CFTunnelIngressRule] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var copiedRuleID: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        let connectorText = tunnel.connectionCount == 1 ? "1 connector" : "\(tunnel.connectionCount) connectors"
        let ledColor = CloudflareView.tunnelLEDColor(for: tunnel.status)

        List {
            Section("Tunnel") {
                HStack(spacing: 10) {
                    CloudStatusLED(color: ledColor, size: 9, glow: tunnel.status == .healthy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tunnel.name)
                            .font(.headline)
                        Text("\(tunnel.status.rawValue.capitalized) · \(connectorText) · \(account.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Exposed Ingress") {
                if let loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await loadIngress(showSpinner: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if rules.isEmpty && !isLoading {
                    Text("No public hostname ingress rules configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        ingressRow(rule)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isLoading && rules.isEmpty {
                ProgressView("Loading Tunnel Ingress…")
            }
        }
        .refreshable {
            await loadIngress(showSpinner: false)
        }
        .navigationTitle(tunnel.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadIngress(showSpinner: rules.isEmpty)
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func ingressRow(_ rule: CFTunnelIngressRule) -> some View {
        let hostname = rule.hostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pathSuffix = rule.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayHost = pathSuffix.isEmpty ? hostname : "\(hostname)\(pathSuffix)"
        let safariURL = CloudflareDNSFormatter.tunnelWebURL(hostname: hostname, path: rule.path)
        let isCopied = copiedRuleID == rule.id

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayHost.isEmpty ? "(Catch-all)" : displayHost)
                    .font(.headline)
                    .textSelection(.enabled)

                Text(rule.service)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !hostname.isEmpty {
                HStack(spacing: 10) {
                    if let safariURL {
                        Button {
                            AppHaptics.impact(.light)
                            openURL(safariURL)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        copyHostname(hostname, ruleID: rule.id)
                    } label: {
                        Label(
                            isCopied ? "Copied" : "Copy Hostname",
                            systemImage: isCopied ? "checkmark" : "doc.on.doc"
                        )
                        .foregroundStyle(isCopied ? Color.green : Color.accentColor)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadIngress(showSpinner: Bool) async {
        guard let token = CloudflareTokenStore.read() else { return }
        if showSpinner {
            isLoading = true
        }
        loadError = nil
        defer { isLoading = false }

        do {
            rules = try await CloudflareClient(token: token).getTunnelIngress(
                accountID: account.id,
                tunnelID: tunnel.id
            )
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func copyHostname(_ hostname: String, ruleID: String) {
        UIPasteboard.general.string = hostname
        AppHaptics.notify(.success)
        copiedRuleID = ruleID
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if copiedRuleID == ruleID {
                copiedRuleID = nil
            }
        }
    }
}

enum CloudflareDNSFormatter {
    static func resolvedRecordName(input: String, zoneName: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanZone = zoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "@" else {
            return cleanZone
        }
        if trimmed == cleanZone || trimmed.hasSuffix(".\(cleanZone)") {
            return trimmed
        }
        return "\(trimmed).\(cleanZone)"
    }

    static func tunnelWebURL(hostname: String, path: String?) -> URL? {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains("*") else {
            return nil
        }
        let urlString = trimmedHost.contains("://") ? trimmedHost : "https://\(trimmedHost)"
        guard var components = URLComponents(string: urlString) else {
            return nil
        }
        if let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            let cleanPath = rawPath.replacingOccurrences(of: "*", with: "")
            if !cleanPath.isEmpty {
                components.path = cleanPath.hasPrefix("/") ? cleanPath : "/\(cleanPath)"
            }
        }
        return components.url
    }
}
