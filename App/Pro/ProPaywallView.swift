import SwiftUI
import StoreKit
import TermUI

/// Apple Pro Dark sheet presenting the one-time TermApp Pro purchase and restore actions.
struct ProPaywallView: View {
    private static let appleProAmber = TerminalTheme.appleProDark.accentColor

    @Environment(ProStore.self) private var proStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var cardFill: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var cardStroke: Color {
        theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    heroHeader
                    featuresCard
                    purchaseSection
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(theme.backgroundColor.ignoresSafeArea())
            .navigationTitle("TermApp Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if proStore.product == nil {
                    await proStore.loadProducts(reportErrors: false)
                }
            }
            .onDisappear {
                proStore.clearError()
            }
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 12) {
            SquircleIcon(
                symbolName: "sparkles",
                tint: Self.appleProAmber,
                fillOpacity: theme.isDark ? 0.22 : 0.14,
                rimOpacity: 0.45,
                size: 64
            )

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("TermApp Pro")
                        .font(.title2.bold())
                        .foregroundStyle(theme.foregroundColor)

                    Text("One-Time Unlock")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Self.appleProAmber)
                        .background(Self.appleProAmber.opacity(0.16), in: Capsule())
                }

                Text("Pay once, keep forever. Core SSH terminal, keys, snippets, and iCloud sync stay free forever.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "folder.fill",
                tint: Self.appleProAmber,
                title: "SFTP File Browser",
                subtitle: "Browse remote directories, preview code and logs, upload, download, rename, and delete files."
            )

            Divider()

            featureRow(
                icon: "arrow.left.arrow.right",
                tint: .green,
                title: "Local Port Forwarding",
                subtitle: "Create -L tunnels to localhost with auto-start rules and 1-tap Open in Safari."
            )

            Divider()

            featureRow(
                icon: "cloud.fill",
                tint: .cyan,
                title: "DigitalOcean & Cloudflare",
                subtitle: "Manage Droplets, 1-tap SSH, sync hosts, edit DNS records, and inspect Zero Trust Tunnels."
            )
        }
        .padding(18)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
    }

    private func featureRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        badge: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SquircleIcon(
                symbolName: icon,
                tint: tint,
                fillOpacity: theme.isDark ? 0.20 : 0.14,
                rimOpacity: 0.36,
                size: 38
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.foregroundColor)

                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.16), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if proStore.isPurchased {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pro Unlocked")
                            .font(.headline)
                            .foregroundStyle(theme.foregroundColor)
                        Text("Thank you for supporting TermApp.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryForegroundColor)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color.green.opacity(theme.isDark ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.green.opacity(0.40), lineWidth: 1)
                )
            } else {
                if proStore.isTestFlight {
                    testFlightNotice("Pro features are unlocked for TestFlight testers.")
                } else {
                    #if DEBUG
                    testFlightNotice("Pro features are unlocked in Debug builds.")
                    #endif
                }

                if let errorMessage = proStore.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    AppHaptics.impact(.light)
                    Task { await proStore.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if proStore.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(purchaseButtonTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Self.appleProAmber)
                .disabled(proStore.isLoading)

                Button {
                    AppHaptics.impact(.light)
                    Task { await proStore.restorePurchases() }
                } label: {
                    Text("Restore Purchases")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(proStore.isLoading)

                Text("One-time purchase. No recurring subscription.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var purchaseButtonTitle: String {
        if proStore.isLoading {
            return "Loading…"
        }
        if let product = proStore.product {
            return "Unlock TermApp Pro — \(product.displayPrice)"
        }
        return "Unlock TermApp Pro"
    }

    private func testFlightNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.foregroundColor)
            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(theme.isDark ? 0.12 : 0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.32), lineWidth: 1)
        )
    }
}
