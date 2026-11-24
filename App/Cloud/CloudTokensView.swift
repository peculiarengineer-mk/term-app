import SwiftUI
import Store
import TermUI

/// Manages local-only DigitalOcean and Cloudflare API tokens, status checks, and minimal-permissions checklists.
struct CloudTokensView: View {
    let showsDoneButton: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    @State private var doTokenInput = ""
    @State private var doBusy = false
    @State private var doStatusMessage: String?
    @State private var doErrorMessage: String?
    @State private var confirmRemoveDO = false

    @State private var cfTokenInput = ""
    @State private var cfBusy = false
    @State private var cfStatusMessage: String?
    @State private var cfErrorMessage: String?
    @State private var confirmRemoveCF = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SquircleIcon(
                        symbolName: "lock.iphone",
                        tint: theme.accentColor,
                        fillOpacity: theme.isDark ? 0.20 : 0.14,
                        rimOpacity: 0.36
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Device-Only Keychain")
                            .font(.headline)
                        Text("Stored locally in this device's Keychain only — never synced to iCloud.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            digitalOceanSection
            cloudflareSection
        }
        .navigationTitle("Cloud Tokens")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            authState.refresh()
        }
        .confirmationDialog(
            "Remove DigitalOcean token?",
            isPresented: $confirmRemoveDO,
            titleVisibility: .visible
        ) {
            Button("Remove Token", role: .destructive) { removeDigitalOceanToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the DigitalOcean token from this device's Keychain. Synced hosts remain saved until you remove them.")
        }
        .confirmationDialog(
            "Remove Cloudflare token?",
            isPresented: $confirmRemoveCF,
            titleVisibility: .visible
        ) {
            Button("Remove Token", role: .destructive) { removeCloudflareToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Cloudflare API token from this device's Keychain.")
        }
    }

    private var digitalOceanSection: some View {
        Section {
            HStack(spacing: 12) {
                SquircleIcon(
                    symbolName: "drop.fill",
                    tint: .blue,
                    fillOpacity: theme.isDark ? 0.22 : 0.14,
                    rimOpacity: 0.36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("DigitalOcean")
                        .font(.headline)
                    HStack(spacing: 6) {
                        CloudStatusLED(
                            color: authState.hasDigitalOceanToken ? .green : .secondary.opacity(0.5),
                            size: 7,
                            glow: authState.hasDigitalOceanToken
                        )
                        Text(authState.hasDigitalOceanToken ? "Connected" : "Not connected")
                            .font(.caption)
                            .foregroundStyle(authState.hasDigitalOceanToken ? .green : .secondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)

            if authState.hasDigitalOceanToken {
                Button {
                    AppHaptics.impact(.light)
                    Task { await testDigitalOceanConnection() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if doBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(doBusy)
            }

            SecureField(
                authState.hasDigitalOceanToken ? "Replace personal access token" : "Personal Access Token (dop_v1_…)",
                text: $doTokenInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.subheadline, design: .monospaced))

            Button {
                AppHaptics.impact(.light)
                Task { await saveDigitalOceanToken() }
            } label: {
                HStack {
                    Text(authState.hasDigitalOceanToken ? "Update Token" : "Save Token")
                    Spacer()
                    if doBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(doTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || doBusy)

            if authState.hasDigitalOceanToken {
                Button("Remove Token", role: .destructive) {
                    confirmRemoveDO = true
                }
                .disabled(doBusy)
            }

            if let doStatusMessage {
                Label(doStatusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let doErrorMessage {
                Label(doErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Minimal Permissions Checklist") {
                CloudScopeChecklistView(scopes: CloudScopeRequirement.digitalOcean, compact: true)
                    .padding(.vertical, 4)
            }
            .font(.subheadline)
        } header: {
            Text("DigitalOcean")
        } footer: {
            Text("Stored locally in this device's Keychain only — never synced to iCloud.")
        }
    }

    private var cloudflareSection: some View {
        Section {
            HStack(spacing: 12) {
                SquircleIcon(
                    symbolName: "cloud.fill",
                    tint: .orange,
                    fillOpacity: theme.isDark ? 0.22 : 0.14,
                    rimOpacity: 0.36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloudflare")
                        .font(.headline)
                    HStack(spacing: 6) {
                        CloudStatusLED(
                            color: authState.hasCloudflareToken ? .green : .secondary.opacity(0.5),
                            size: 7,
                            glow: authState.hasCloudflareToken
                        )
                        Text(authState.hasCloudflareToken ? "Connected" : "Not connected")
                            .font(.caption)
                            .foregroundStyle(authState.hasCloudflareToken ? .green : .secondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)

            if authState.hasCloudflareToken {
                Button {
                    AppHaptics.impact(.light)
                    Task { await verifyStoredCloudflareToken() }
                } label: {
                    HStack {
                        Text("Verify Token")
                        Spacer()
                        if cfBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(cfBusy)
            }

            SecureField(
                authState.hasCloudflareToken ? "Replace Cloudflare API token" : "Cloudflare API Token",
                text: $cfTokenInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.subheadline, design: .monospaced))

            Button {
                AppHaptics.impact(.light)
                Task { await saveCloudflareToken() }
            } label: {
                HStack {
                    Text(authState.hasCloudflareToken ? "Verify & Update Token" : "Verify & Connect")
                    Spacer()
                    if cfBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(cfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cfBusy)

            if authState.hasCloudflareToken {
                Button("Remove Token", role: .destructive) {
                    confirmRemoveCF = true
                }
                .disabled(cfBusy)
            }

            if let cfStatusMessage {
                Label(cfStatusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let cfErrorMessage {
                Label(cfErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Minimal Permissions Checklist") {
                CloudScopeChecklistView(scopes: CloudScopeRequirement.cloudflare, compact: true)
                    .padding(.vertical, 4)
            }
            .font(.subheadline)
        } header: {
            Text("Cloudflare")
        } footer: {
            Text("Stored locally in this device's Keychain only — never synced to iCloud.")
        }
    }

    private func saveDigitalOceanToken() async {
        let trimmed = doTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        doBusy = true
        doStatusMessage = nil
        doErrorMessage = nil
        defer { doBusy = false }

        do {
            let droplets = try await DigitalOceanClient(token: trimmed).listDroplets()
            try authState.saveDigitalOceanToken(trimmed)
            doTokenInput = ""
            let noun = droplets.count == 1 ? "Droplet" : "Droplets"
            doStatusMessage = "Verified and saved (\(droplets.count) \(noun))."
            AppHaptics.notify(.success)
        } catch {
            doErrorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func testDigitalOceanConnection() async {
        guard let token = DigitalOceanTokenStore.read() else {
            authState.refresh()
            return
        }
        doBusy = true
        doStatusMessage = nil
        doErrorMessage = nil
        defer { doBusy = false }

        do {
            let droplets = try await DigitalOceanClient(token: token).listDroplets()
            let noun = droplets.count == 1 ? "Droplet" : "Droplets"
            doStatusMessage = "Token valid (\(droplets.count) \(noun))."
            AppHaptics.notify(.success)
        } catch {
            doErrorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func removeDigitalOceanToken() {
        doStatusMessage = nil
        doErrorMessage = nil
        do {
            try authState.deleteDigitalOceanToken()
            AppHaptics.notify(.warning)
        } catch {
            doErrorMessage = error.localizedDescription
        }
    }

    private func saveCloudflareToken() async {
        let trimmed = cfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cfBusy = true
        cfStatusMessage = nil
        cfErrorMessage = nil
        defer { cfBusy = false }

        do {
            let isActive = try await CloudflareClient(token: trimmed).verifyToken()
            guard isActive else {
                cfErrorMessage = "Cloudflare token is not active."
                AppHaptics.notify(.error)
                return
            }
            try authState.saveCloudflareToken(trimmed)
            cfTokenInput = ""
            cfStatusMessage = "Cloudflare token verified and saved."
            AppHaptics.notify(.success)
        } catch {
            cfErrorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func verifyStoredCloudflareToken() async {
        guard let token = CloudflareTokenStore.read() else {
            authState.refresh()
            return
        }
        cfBusy = true
        cfStatusMessage = nil
        cfErrorMessage = nil
        defer { cfBusy = false }

        do {
            let isActive = try await CloudflareClient(token: token).verifyToken()
            if isActive {
                cfStatusMessage = "Cloudflare token is active."
                AppHaptics.notify(.success)
            } else {
                cfErrorMessage = "Cloudflare token is not active."
                AppHaptics.notify(.error)
            }
        } catch {
            cfErrorMessage = error.localizedDescription
            AppHaptics.notify(.error)
        }
    }

    private func removeCloudflareToken() {
        cfStatusMessage = nil
        cfErrorMessage = nil
        do {
            try authState.deleteCloudflareToken()
            AppHaptics.notify(.warning)
        } catch {
            cfErrorMessage = error.localizedDescription
        }
    }
}
