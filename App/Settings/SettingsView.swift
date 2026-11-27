import SwiftUI
import CoreText
import TermUI

struct SettingsView: View {
    @Environment(AppLockManager.self) private var appLock
    @Environment(ProStore.self) private var proStore
    @AppStorage("sync.enabled") private var syncEnabled = false
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage(AppearanceSettings.fontSizeKey) private var fontSize = AppearanceSettings.defaultFontSize
    @AppStorage(AppearanceSettings.fontFamilyKey) private var fontFamilyRaw = AppearanceSettings.defaultFontFamilyRaw
    @AppStorage(AppearanceSettings.cursorStyleKey) private var cursorStyleRaw = AppearanceSettings.defaultCursorStyleRaw
    @AppStorage(AppearanceSettings.hapticsKey) private var hapticsEnabled = AppearanceSettings.defaultHapticsEnabled
    @AppStorage(AgentNotificationManager.notificationsEnabledKey) private var agentNotificationsEnabled = true
    @State private var securityError: String?
    @State private var showingPaywall = false

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var currentTheme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: currentTheme) }

    private var cloudTokensSummary: String {
        switch (authState.hasDigitalOceanToken, authState.hasCloudflareToken) {
        case (true, true): "DigitalOcean · Cloudflare"
        case (true, false): "DigitalOcean"
        case (false, true): "Cloudflare"
        case (false, false): "Not configured"
        }
    }
    private var fontFamily: TerminalFontFamily { TerminalFontFamily(rawValue: fontFamilyRaw) ?? .sfMono }
    private var cursorStyle: TerminalCursorStyle { TerminalCursorStyle(rawValue: cursorStyleRaw) ?? .block }

    private var previewFont: Font {
        Font(fontFamily.uiFont(ofSize: CGFloat(fontSize)) as CTFont)
    }

    private var proStatusTitle: String {
        Self.proStatusTitle(for: proStore.activePlan, isTestFlight: proStore.isTestFlight)
    }

    nonisolated static func proStatusTitle(
        for activePlan: ProStore.ActivePlan,
        isTestFlight: Bool,
        isDebugBuild: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
    ) -> String {
        switch activePlan {
        case .lifetime:
            return "Pro Unlocked (Lifetime)"
        case .annual:
            return "Pro Unlocked (Annual)"
        case .none:
            if isTestFlight {
                return "Pro Unlocked (TestFlight)"
            }
            if isDebugBuild {
                return "Pro Unlocked (Debug)"
            }
            return "Upgrade to Pro"
        }
    }

    nonisolated static func proTrailingPriceText(
        annualDisplayPrice: String?,
        lifetimeDisplayPrice: String?
    ) -> String {
        if let annualDisplayPrice {
            return "From \(annualDisplayPrice)/yr"
        }
        if let lifetimeDisplayPrice {
            return lifetimeDisplayPrice
        }
        return "From $9.99/yr"
    }

    var body: some View {
        Form {
            proSection

            Section("Appearance") {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    AdaptiveKeyValueRow {
                        Text("Theme")
                    } trailing: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(currentTheme.backgroundColor)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.75))
                                .frame(width: 14, height: 14)
                            Text(currentTheme.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(TerminalFontFamily.allCases) { family in
                        Text(family.rawValue).tag(family.rawValue)
                    }
                }

                Picker("Cursor", selection: $cursorStyleRaw) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    AdaptiveKeyValueRow {
                        Text("Font Size")
                    } trailing: {
                        Text(AppearanceSettings.formattedFontSize(fontSize))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: $fontSize,
                            in: AppearanceSettings.minFontSize...AppearanceSettings.maxFontSize,
                            step: 0.5
                        ) {
                            Text("Font Size")
                        }
                        Image(systemName: "textformat.size.larger")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .bottom, spacing: 0) {
                            Text("dev@prod")
                                .foregroundStyle(currentTheme.ansi[2].color)
                            Text(":~/app$ ")
                                .foregroundStyle(currentTheme.ansi[4].color)
                            Text("ssh -V")
                                .foregroundStyle(currentTheme.foregroundColor)
                            previewCursor
                                .padding(.leading, 2)
                        }
                        Text("OpenSSH_9.9, libssh2 PQ")
                            .foregroundStyle(currentTheme.secondaryForegroundColor)
                    }
                    .font(previewFont)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(currentTheme.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                currentTheme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Terminal preview: \(fontFamily.rawValue), \(AppearanceSettings.formattedFontSize(fontSize)), \(cursorStyle.rawValue.lowercased()) cursor")
                }
                .padding(.vertical, 4)

                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                    .onChange(of: hapticsEnabled) { _, on in
                        if on { AppHaptics.impact(.light) }
                    }
            }

            Section {
                NavigationLink("Command Snippets", destination: SnippetDrawerView(onRun: nil))
            }

            Section {
                Toggle("Agent Alerts", isOn: $agentNotificationsEnabled)
                    .onChange(of: agentNotificationsEnabled) { _, on in
                        if on {
                            AppHaptics.impact(.light)
                            AgentNotificationManager.shared.requestAuthorizationIfNeeded()
                        }
                    }
            } header: {
                Text("AI Agents")
            } footer: {
                Text("Fires haptics and local notifications when an AI agent waits for approval or finishes responding while you are away or on another tab.")
            }

            Section("Cloud") {
                NavigationLink {
                    CloudTokensView(showsDoneButton: false)
                } label: {
                    AdaptiveKeyValueRow {
                        Text("Cloud Tokens")
                    } trailing: {
                        Text(cloudTokensSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Face ID / Passcode Lock", isOn: Binding(
                    get: { appLock.appLockEnabled },
                    set: { enabled in
                        if enabled {
                            Task {
                                if let error = await appLock.enableWithAuthentication() {
                                    securityError = error
                                }
                            }
                        } else {
                            Task {
                                if await appLock.disableWithAuthentication() {
                                    securityError = nil
                                }
                            }
                        }
                    }
                ))
                .disabled(appLock.isAuthenticating)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks TermApp on launch and when returning from the background. Terminal screens are always blurred in the App Switcher.")
            }

            Section {
                Toggle("iCloud sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, on in
                        guard !on else { return }
                        SyncCoordinator.syncTurnedOff()
                    }
            } footer: {
                Text("Syncs saved hosts, saved passwords and trusted host keys through iCloud. Takes effect the next time the app opens. Turning sync off keeps everything on this device and leaves what is already in iCloud in place.")
            }
            aboutLegalSection
            #if DEBUG
            Section("Debug") {
                NavigationLink("Sync tools", destination: DebugSyncTools())
            }
            #endif
            Section {
                Text("To use Caps Lock as a modifier key, open Settings › General › Keyboard › Hardware Keyboard › Modifier Keys.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            authState.refresh()
        }
        .alert(
            "App Lock Unavailable",
            isPresented: Binding(get: { securityError != nil }, set: { if !$0 { securityError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(securityError ?? "")
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: currentTheme))
                .tint(currentTheme.accentColor)
        }
    }

    private var appVersionSummary: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var aboutLegalSection: some View {
        Section("About & Legal") {
            AdaptiveKeyValueRow {
                Text("Version")
            } trailing: {
                Text(appVersionSummary)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            externalLinkRow(
                title: "Privacy Policy",
                urlString: "https://github.com/peculiarengineer-mk/term-app/blob/main/PRIVACY.md"
            )

            externalLinkRow(
                title: "Terms of Use",
                urlString: "https://github.com/peculiarengineer-mk/term-app/blob/main/TERMS.md"
            )

            externalLinkRow(
                title: "Support & Feedback",
                urlString: "https://github.com/peculiarengineer-mk/term-app/blob/main/SUPPORT.md"
            )

            externalLinkRow(
                title: "Report an Issue",
                urlString: "https://github.com/peculiarengineer-mk/term-app/issues"
            )

            NavigationLink("Licences", destination: LicencesView())

            Button("Replay Welcome Guide") {
                AppHaptics.impact(.light)
                NotificationCenter.default.post(name: Notification.Name("TermAppReplayOnboarding"), object: nil)
            }
        }
    }

    @ViewBuilder
    private func externalLinkRow(title: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var proSection: some View {
        Section("TermApp Pro") {
            Button {
                AppHaptics.impact(.light)
                showingPaywall = true
            } label: {
                HStack(spacing: 12) {
                    ProSquircleIcon(
                        symbolName: proStore.isProUnlocked ? "checkmark.seal.fill" : "sparkles",
                        tint: proStore.isProUnlocked ? palette.healthy : palette.proBrandAmber,
                        size: .row,
                        theme: currentTheme
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(proStatusTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("AI Agents, SFTP, Port Forwarding, DigitalOcean & Cloudflare")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if !proStore.isProUnlocked {
                        Text(
                            Self.proTrailingPriceText(
                                annualDisplayPrice: proStore.annualProduct?.displayPrice,
                                lifetimeDisplayPrice: proStore.lifetimeProduct?.displayPrice
                            )
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.proBrandAmber)
                        .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var previewCursor: some View {
        let cellHeight = max(10, CGFloat(fontSize) * 1.15)
        let cellWidth = max(6, CGFloat(fontSize) * 0.58)
        let stroke = max(2, CGFloat(fontSize) * 0.14)

        switch cursorStyle {
        case .block:
            Rectangle()
                .fill(currentTheme.cursor.color)
                .frame(width: cellWidth, height: cellHeight)
        case .bar:
            Rectangle()
                .fill(currentTheme.cursor.color)
                .frame(width: stroke, height: cellHeight)
        case .underline:
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: cellWidth, height: cellHeight)
                Rectangle()
                    .fill(currentTheme.cursor.color)
                    .frame(width: cellWidth, height: stroke)
            }
        }
    }
}
