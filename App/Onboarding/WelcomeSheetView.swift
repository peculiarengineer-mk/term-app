import SwiftUI
import TermUI

/// Three-page Apple Pro Dark welcome tour shown on first launch and replayable from Settings.
struct WelcomeSheetView: View {
    private struct WelcomeHighlight: Identifiable {
        let id: String
        let symbolName: String
        let tint: Color
        let title: String
        let detail: String
    }

    private struct WelcomePage: Identifiable {
        let id: Int
        let eyebrow: String
        let heroSymbol: String
        let heroTint: Color
        let title: String
        let subtitle: String
        let highlights: [WelcomeHighlight]
    }

    private static let appleProAmber = TerminalTheme.appleProDark.accentColor

    private static let pages: [WelcomePage] = [
        WelcomePage(
            id: 0,
            eyebrow: "Security First",
            heroSymbol: "lock.shield.fill",
            heroTint: .green,
            title: "Post-Quantum SSH & Hardware Keys",
            subtitle: "Modern cryptography and hardware-backed identity, with every credential kept strictly on your device.",
            highlights: [
                WelcomeHighlight(
                    id: "pq-kex",
                    symbolName: "atom",
                    tint: .green,
                    title: "ML-KEM-768 Post-Quantum KEX",
                    detail: "Hybrid mlkem768x25519 key exchange protects sessions alongside modern AEAD ciphers."
                ),
                WelcomeHighlight(
                    id: "hardware-keys",
                    symbolName: "cpu",
                    tint: appleProAmber,
                    title: "Secure Enclave P-256 & Ed25519",
                    detail: "Generate hardware-bound Secure Enclave keys or import and manage Ed25519 identities."
                ),
                WelcomeHighlight(
                    id: "faceid-lock",
                    symbolName: "faceid",
                    tint: .cyan,
                    title: "Face ID Lock & Privacy Veil",
                    detail: "Lock the app with Face ID or passcode and blur active terminals in the App Switcher."
                ),
                WelcomeHighlight(
                    id: "zero-telemetry",
                    symbolName: "eye.slash.fill",
                    tint: .mint,
                    title: "Zero Telemetry",
                    detail: "No analytics SDKs, no tracking, and local Keychain secrets stay on your device."
                ),
            ]
        ),
        WelcomePage(
            id: 1,
            eyebrow: "AI Agent Cockpit",
            heroSymbol: "sparkles",
            heroTint: appleProAmber,
            title: "Mobile AI Agent Cockpit",
            subtitle: "Launch, guide, and inspect remote coding agents without losing context when switching apps.",
            highlights: [
                WelcomeHighlight(
                    id: "tmux-agents",
                    symbolName: "terminal.fill",
                    tint: appleProAmber,
                    title: "Persistent tmux Sessions",
                    detail: "Run Claude Code, Antigravity (agy), and Codex in tmux so sessions survive disconnects."
                ),
                WelcomeHighlight(
                    id: "prompt-composer",
                    symbolName: "photo.badge.plus",
                    tint: .purple,
                    title: "Prompt Composer & Photo Attach",
                    detail: "Draft multi-line prompts comfortably and upload screenshots straight to your workspace."
                ),
                WelcomeHighlight(
                    id: "git-diff",
                    symbolName: "doc.text.magnifyingglass",
                    tint: .blue,
                    title: "Mobile Git Diff Inspector",
                    detail: "Inspect changed files and unified diffs, discard edits, or commit from your phone."
                ),
                WelcomeHighlight(
                    id: "dev-preview",
                    symbolName: "safari.fill",
                    tint: .green,
                    title: "1-Tap Dev Server Preview",
                    detail: "Detect listening ports, tunnel automatically over -L, and preview live builds in-app."
                ),
            ]
        ),
        WelcomePage(
            id: 2,
            eyebrow: "Cloud Infrastructure",
            heroSymbol: "cloud.fill",
            heroTint: .cyan,
            title: "Cloud Infrastructure in Your Pocket",
            subtitle: "Control servers, DNS, Zero Trust Tunnels, and remote files directly from iPhone or iPad.",
            highlights: [
                WelcomeHighlight(
                    id: "digitalocean",
                    symbolName: "server.rack",
                    tint: .cyan,
                    title: "DigitalOcean Droplets",
                    detail: "Create Droplets, run power actions, push local SSH keys, and connect in one tap."
                ),
                WelcomeHighlight(
                    id: "cloudflare",
                    symbolName: "network",
                    tint: appleProAmber,
                    title: "Cloudflare DNS & Zero Trust",
                    detail: "Browse zones, edit DNS records, and inspect Cloudflare Zero Trust Tunnel status."
                ),
                WelcomeHighlight(
                    id: "sftp",
                    symbolName: "folder.fill",
                    tint: .blue,
                    title: "SFTP File Browser",
                    detail: "Navigate remote directories, preview code and logs, and upload or download files."
                ),
                WelcomeHighlight(
                    id: "port-forwards",
                    symbolName: "arrow.left.arrow.right",
                    tint: .green,
                    title: "Local -L Port Forwarding",
                    detail: "Create localhost SSH tunnels with auto-start rules and instant Safari preview."
                ),
            ]
        ),
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var currentPage = 0

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }
    private var isLastPage: Bool { currentPage >= Self.pages.count - 1 }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private func resolvedTint(_ rawTint: Color) -> Color {
        rawTint == Self.appleProAmber ? palette.proBrandAmber : rawTint
    }

    private var cardFill: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var cardStroke: Color {
        theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            TabView(selection: $currentPage) {
                ForEach(Self.pages) { page in
                    pageView(page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: theme.isDark ? .automatic : .always))

            bottomBar
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .onChange(of: currentPage) { _, _ in
            AppHaptics.impact(.light)
        }
    }

    private var topBar: some View {
        HStack {
            Text("\(currentPage + 1) of \(Self.pages.count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(theme.secondaryForegroundColor)
                .accessibilityLabel("Page \(currentPage + 1) of \(Self.pages.count)")

            Spacer()

            Button("Skip") {
                AppHaptics.impact(.light)
                dismiss()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.secondaryForegroundColor)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isLastPage ? 0 : 1)
            .disabled(isLastPage)
            .accessibilityHidden(isLastPage)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func pageView(_ page: WelcomePage) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: isCompactHeight ? 14 : 20) {
                VStack(spacing: isCompactHeight ? 8 : 12) {
                    let heroTint = resolvedTint(page.heroTint)
                    SquircleIcon(
                        symbolName: page.heroSymbol,
                        tint: heroTint,
                        fillOpacity: theme.isDark ? 0.22 : 0.14,
                        rimOpacity: 0.45,
                        size: isCompactHeight ? 52 : 64
                    )

                    Text(page.eyebrow)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(heroTint)
                        .background(heroTint.opacity(theme.isDark ? 0.18 : 0.12), in: Capsule())

                    Text(page.title)
                        .font(.title2.bold())
                        .foregroundStyle(theme.foregroundColor)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(page.highlights.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        highlightRow(item)
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
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func highlightRow(_ item: WelcomeHighlight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SquircleIcon(
                symbolName: item.symbolName,
                tint: resolvedTint(item.tint),
                fillOpacity: theme.isDark ? 0.20 : 0.14,
                rimOpacity: 0.36,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button {
                if isLastPage {
                    AppHaptics.notify(.success)
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        currentPage = min(currentPage + 1, Self.pages.count - 1)
                    }
                }
            } label: {
                Text(isLastPage ? "Get Started" : "Continue")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.proBrandAmberButtonInk)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(palette.proBrandAmber)
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }
}
