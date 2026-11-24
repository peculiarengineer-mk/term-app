import SwiftUI
import TermUI

/// Top-level Cloud tab hosting DigitalOcean Droplets and Cloudflare DNS & Zero Trust Tunnels.
struct CloudTabView: View {
    private enum Provider: String, CaseIterable, Identifiable {
        case digitalOcean = "DigitalOcean"
        case cloudflare = "Cloudflare"

        var id: String { rawValue }
    }

    private static let appleProAmber = TerminalTheme.appleProDark.accentColor

    @Environment(ProStore.self) private var proStore
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var selectedProvider: Provider = .digitalOcean
    @State private var showingTokensSheet = false
    @State private var showingPaywall = false

    private var authState: CloudAuthState { CloudAuthState.shared }
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        Group {
            if proStore.isProUnlocked {
                VStack(spacing: 0) {
                    providerPickerBar

                    switch selectedProvider {
                    case .digitalOcean:
                        DigitalOceanView(onOpenTokenSettings: { showingTokensSheet = true })
                    case .cloudflare:
                        CloudflareView(onOpenTokenSettings: { showingTokensSheet = true })
                    }
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
                    Label("Cloud Tokens", systemImage: "gearshape")
                }
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
            .tint(theme.accentColor)
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
        }
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
        let cardFill = theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        let cardStroke = theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)

        return ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    SquircleIcon(
                        symbolName: "cloud.fill",
                        tint: Self.appleProAmber,
                        fillOpacity: theme.isDark ? 0.22 : 0.14,
                        rimOpacity: 0.44,
                        size: 60
                    )

                    Text("Cloud Infrastructure")
                        .font(.title3.bold())

                    Text("Manage DigitalOcean Droplets, Cloudflare DNS records, and Zero Trust Tunnels directly from TermApp.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 14) {
                    proFeatureRow(
                        icon: "drop.fill",
                        tint: .blue,
                        title: "DigitalOcean Droplets",
                        detail: "Spin up Droplets, 1-tap SSH, power actions, host sync, and SSH key push."
                    )

                    Divider()

                    proFeatureRow(
                        icon: "globe",
                        tint: .orange,
                        title: "Cloudflare DNS & Tunnels",
                        detail: "Edit zone DNS records with 1-tap Droplet IPs and inspect Zero Trust Tunnel ingress."
                    )
                }
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )

                Button {
                    AppHaptics.impact(.light)
                    showingPaywall = true
                } label: {
                    Label("Unlock TermApp Pro", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Self.appleProAmber)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func proFeatureRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SquircleIcon(
                symbolName: icon,
                tint: tint,
                fillOpacity: theme.isDark ? 0.20 : 0.14,
                rimOpacity: 0.36,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
