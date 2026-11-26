import SwiftUI
import SwiftData
import Store
import TermUI

/// Observable cache of local cloud API token presence so Cloud, Keys, and Settings stay in sync.
@MainActor @Observable
final class CloudAuthState {
    static let shared = CloudAuthState()

    private(set) var hasDigitalOceanToken: Bool
    private(set) var hasCloudflareToken: Bool

    private init() {
        hasDigitalOceanToken = DigitalOceanTokenStore.hasToken
        hasCloudflareToken = CloudflareTokenStore.hasToken
    }

    func refresh() {
        hasDigitalOceanToken = DigitalOceanTokenStore.hasToken
        hasCloudflareToken = CloudflareTokenStore.hasToken
    }

    func saveDigitalOceanToken(_ token: String) throws {
        try DigitalOceanTokenStore.save(token)
        hasDigitalOceanToken = DigitalOceanTokenStore.hasToken
    }

    func deleteDigitalOceanToken() throws {
        try DigitalOceanTokenStore.delete()
        hasDigitalOceanToken = DigitalOceanTokenStore.hasToken
    }

    func saveCloudflareToken(_ token: String) throws {
        try CloudflareTokenStore.save(token)
        hasCloudflareToken = CloudflareTokenStore.hasToken
    }

    func deleteCloudflareToken() throws {
        try CloudflareTokenStore.delete()
        hasCloudflareToken = CloudflareTokenStore.hasToken
    }
}

/// Guided permission scope entry displayed during token onboarding and in Cloud Tokens settings.
struct CloudScopeRequirement: Identifiable, Hashable {
    let scope: String
    let purpose: String

    var id: String { scope }

    static let digitalOcean: [CloudScopeRequirement] = [
        CloudScopeRequirement(scope: "droplet:create", purpose: "Spin up new Droplets"),
        CloudScopeRequirement(scope: "droplet:read", purpose: "List Droplets and public IPs"),
        CloudScopeRequirement(scope: "droplet:delete", purpose: "Destroy Droplets from the app"),
        CloudScopeRequirement(scope: "ssh_key:create", purpose: "Push device SSH keys to your account"),
        CloudScopeRequirement(scope: "ssh_key:read", purpose: "Select account SSH keys on create"),
    ]

    static let cloudflare: [CloudScopeRequirement] = [
        CloudScopeRequirement(scope: "Zone:DNS:Edit", purpose: "View zones and create, edit, or delete DNS records"),
        CloudScopeRequirement(scope: "Account:Cloudflare Tunnel:Read", purpose: "List Zero Trust Tunnels and exposed hostnames"),
    ]
}

/// Small glowing LED dot for Droplet power state, Tunnel health, and token status.
struct CloudStatusLED: View {
    let color: Color
    var size: CGFloat = 8
    var glow: Bool = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.6) : .clear, radius: glow ? 3 : 0)
            .accessibilityHidden(true)
    }
}

/// Renders minimal-permissions checklist items in Apple Pro monospace styling.
struct CloudScopeChecklistView: View {
    let scopes: [CloudScopeRequirement]
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            ForEach(scopes) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.scope)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        Text(item.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Shared Apple Pro Dark onboarding card for DigitalOcean and Cloudflare token setup.
struct CloudTokenOnboardingCard: View {
    let symbolName: String
    let tint: Color
    let title: String
    let subtitle: String
    let scopes: [CloudScopeRequirement]
    let placeholder: String
    let buttonTitle: String
    @Binding var tokenInput: String
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: () -> Void

    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @FocusState private var isTokenFieldFocused: Bool

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var cardFill: Color {
        theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    private var cardStroke: Color {
        theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    private var canSubmit: Bool {
        !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isConnecting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    SquircleIcon(
                        symbolName: symbolName,
                        tint: tint,
                        fillOpacity: theme.isDark ? 0.22 : 0.14,
                        rimOpacity: 0.42,
                        size: 56
                    )

                    VStack(spacing: 6) {
                        Text(title)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)

                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Minimal Permissions Checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    CloudScopeChecklistView(scopes: scopes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 12) {
                    SecureField(placeholder, text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .monospaced))
                        .focused($isTokenFieldFocused)
                        .submitLabel(.go)
                        .onSubmit {
                            if canSubmit { onConnect() }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isTokenFieldFocused ? theme.accentColor.opacity(0.75) : cardStroke,
                                    lineWidth: 1
                                )
                        )

                    if let errorMessage, !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        AppHaptics.impact(.light)
                        isTokenFieldFocused = false
                        onConnect()
                    } label: {
                        HStack(spacing: 8) {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isConnecting ? "Verifying…" : buttonTitle)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)

                    HStack(spacing: 6) {
                        Image(systemName: "lock.iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Stored locally in this device's Keychain only — never synced to iCloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Synchronizes DigitalOcean Droplets with SwiftData `Host` records (`source == "droplet"`).
enum CloudHostSync {
    struct Result: Equatable {
        let upserted: Int
        let removed: Int

        var summaryMessage: String {
            var parts: [String] = []
            if upserted > 0 {
                parts.append(upserted == 1 ? "1 Droplet host synced" : "\(upserted) Droplet hosts synced")
            } else {
                parts.append("No active Droplets with public IPv4")
            }
            if removed > 0 {
                parts.append(removed == 1 ? "1 stale host removed" : "\(removed) stale hosts removed")
            }
            return parts.joined(separator: " · ")
        }
    }

    @MainActor
    static func preferredSSHAuth(matchingAccountKeys accountKeys: [DOSSHKey] = []) -> (authMethod: String, keyID: UUID?) {
        let localKeys = (try? KeyStore().list()) ?? []
        guard !localKeys.isEmpty else {
            return ("password", nil)
        }
        if !accountKeys.isEmpty {
            let accountKeyValues = Set(accountKeys.map { normalizePublicKey($0.publicKey) }.filter { !$0.isEmpty })
            if let matched = localKeys.first(where: { accountKeyValues.contains(normalizePublicKey($0.publicKey)) }) {
                return ("key", matched.id)
            }
        }
        return ("key", localKeys.first?.id)
    }

    static func normalizePublicKey(_ key: String) -> String {
        let parts = key.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(parts[0]) \(parts[1])"
    }

    @MainActor
    static func sync(
        droplets: [DODroplet],
        accountKeys: [DOSSHKey] = [],
        in context: ModelContext
    ) throws -> Result {
        let existingAll = try context.fetch(FetchDescriptor<Host>())
        var dropletHosts = existingAll.filter { $0.source == "droplet" }
        var matchedIDs = Set<UUID>()
        var upserted = 0
        let defaultAuth = preferredSSHAuth(matchingAccountKeys: accountKeys)

        for droplet in droplets {
            guard droplet.isActive,
                  let rawIP = droplet.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawIP.isEmpty else {
                continue
            }

            let targetTags = normalizedDropletTags(regionSlug: droplet.regionSlug)
            if let matchIndex = dropletHosts.firstIndex(where: { !matchedIDs.contains($0.id) && $0.hostname == rawIP })
                ?? dropletHosts.firstIndex(where: { !matchedIDs.contains($0.id) && $0.label == droplet.name }) {
                let host = dropletHosts[matchIndex]
                matchedIDs.insert(host.id)
                var changed = false
                if host.hostname != rawIP {
                    host.hostname = rawIP
                    changed = true
                }
                if host.label != droplet.name {
                    host.label = droplet.name
                    changed = true
                }
                if host.username.isEmpty {
                    host.username = "root"
                    changed = true
                }
                if host.tags != targetTags {
                    host.tags = targetTags
                    changed = true
                }
                if host.authMethod == "key", host.keyID == nil, let defaultKeyID = defaultAuth.keyID {
                    host.keyID = defaultKeyID
                    changed = true
                }
                if changed {
                    host.touch()
                }
            } else {
                let newHost = Host(
                    label: droplet.name,
                    hostname: rawIP,
                    port: 22,
                    username: "root",
                    authMethod: defaultAuth.authMethod,
                    keyID: defaultAuth.keyID,
                    tags: targetTags,
                    source: "droplet"
                )
                context.insert(newHost)
                dropletHosts.append(newHost)
                matchedIDs.insert(newHost.id)
            }
            upserted += 1
        }

        // Keep hosts pointing at existing non-active droplets that still hold their IPv4; prune everything else.
        let existingNonActiveIPs = Set(
            droplets
                .filter { !$0.isActive }
                .compactMap { $0.publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        var removed = 0
        for host in dropletHosts where !matchedIDs.contains(host.id) {
            if existingNonActiveIPs.contains(host.hostname) {
                continue
            }
            let hostID = host.id
            context.delete(host)
            HostSecrets.deletePassword(for: hostID)
            PortForwardStore.deleteAll(for: hostID)
            HostProjectStore.deleteAll(for: hostID)
            AISessionCacheStore.removeAll(for: hostID)
            removed += 1
        }

        try context.save()
        return Result(upserted: upserted, removed: removed)
    }

    @MainActor
    static func deleteSyncedHosts(forHostname ipv4: String?, in context: ModelContext) {
        guard let ip = ipv4?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else { return }
        guard let all = try? context.fetch(FetchDescriptor<Host>()) else { return }
        let matches = all.filter { $0.source == "droplet" && $0.hostname == ip }
        guard !matches.isEmpty else { return }
        for host in matches {
            let hostID = host.id
            context.delete(host)
            HostSecrets.deletePassword(for: hostID)
            PortForwardStore.deleteAll(for: hostID)
            HostProjectStore.deleteAll(for: hostID)
            AISessionCacheStore.removeAll(for: hostID)
        }
        try? context.save()
    }

    static func normalizedDropletTags(regionSlug: String) -> [String] {
        let region = regionSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return region.isEmpty ? ["do"] : ["do", region]
    }
}
