import SwiftUI
import TermUI

/// Top-level Cloud tab hosting DigitalOcean Droplets and Cloudflare DNS & Zero Trust Tunnels.
struct CloudTabView: View {
    private enum Provider: String, CaseIterable, Identifiable {
        case digitalOcean = "DigitalOcean"
        case cloudflare = "Cloudflare"

        var id: String { rawValue }
    }

    @Environment(ProStore.self) private var proStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var selectedProvider: Provider = .digitalOcean
    @State private var showingTokensSheet = false
    @State private var showingPaywall = false

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    var body: some View {
        Group {
            if proStore.isProUnlocked {
                if horizontalSizeClass == .regular {
                    regularSplitLayout
                } else {
                    compactLayout
                }
            } else {
                proPromptView
            }
        }
        .navigationTitle("Cloud")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    AppHaptics.impact(.light)
                    showingTokensSheet = true
                } label: {
                    Image(systemName: "key.horizontal")
                }
                .accessibilityLabel("Cloud Tokens")
            }
        }
        .onAppear {
            authState.refresh()
        }
        .sheet(isPresented: $showingTokensSheet) {
            NavigationStack {
                CloudTokensView(showsDoneButton: true)
            }
            .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
            .tint(palette.accent)
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(palette.proBrandAmber)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            providerPickerBar

            switch selectedProvider {
            case .digitalOcean:
                DigitalOceanView(onOpenTokenSettings: { showingTokensSheet = true })
            case .cloudflare:
                CloudflareView(onOpenTokenSettings: { showingTokensSheet = true })
            }
        }
    }

    private var regularSplitLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                DigitalOceanView(
                    onOpenTokenSettings: { showingTokensSheet = true },
                    showsInlineHeaderActions: true
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 0) {
                providerPaneHeader(
                    title: Provider.cloudflare.rawValue,
                    symbolName: "globe",
                    tint: .orange,
                    isConnected: authState.hasCloudflareToken
                )
                Divider()
                CloudflareView(onOpenTokenSettings: { showingTokensSheet = true })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func providerPaneHeader(
        title: String,
        symbolName: String,
        tint: Color,
        isConnected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            ProSquircleIcon(
                symbolName: symbolName,
                tint: tint,
                size: .compact,
                theme: theme,
                statusLED: isConnected ? palette.healthy : nil,
                statusGlow: isConnected
            )

            Text(title)
                .font(.headline)

            Spacer()

            Text(isConnected ? "Connected" : "Token Required")
                .font(.caption.weight(.medium))
                .foregroundStyle(isConnected ? palette.healthy : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var providerPickerBar: some View {
        VStack(spacing: 0) {
            Picker("Cloud Provider", selection: $selectedProvider) {
                ForEach(Provider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: selectedProvider) { _, _ in
                AppHaptics.impact(.light)
            }

            Divider()
        }
        .background(.bar)
    }

    private var proPromptView: some View {
        ProFeatureGateView(
            symbolName: "cloud.fill",
            title: "Cloud Infrastructure",
            subtitle: "Manage DigitalOcean Droplets, Cloudflare DNS records, and Zero Trust Tunnels directly from AmberTTY.",
            features: [
                ProFeatureItem(
                    icon: "drop.fill",
                    tint: .blue,
                    title: "DigitalOcean Droplets",
                    detail: "Spin up Droplets, 1-tap SSH, power actions, host sync, and SSH key push."
                ),
                ProFeatureItem(
                    icon: "globe",
                    tint: .orange,
                    title: "Cloudflare DNS & Tunnels",
                    detail: "Edit zone DNS records with 1-tap Droplet IPs and inspect Zero Trust Tunnel ingress."
                ),
            ],
            theme: theme,
            onUnlock: { showingPaywall = true }
        )
    }
}
