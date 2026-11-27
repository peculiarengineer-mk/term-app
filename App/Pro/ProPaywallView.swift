import SwiftUI
import StoreKit
import TermUI

/// Apple Pro Dark sheet presenting the hybrid AmberTTY Pro Annual subscription and Lifetime purchase.
struct ProPaywallView: View {
    enum PlanChoice: String, CaseIterable, Identifiable, Sendable {
        case annual
        case lifetime

        var id: String { rawValue }

        var productID: String {
            switch self {
            case .annual: ProStore.annualProductID
            case .lifetime: ProStore.lifetimeProductID
            }
        }
    }

    @Environment(ProStore.self) private var proStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var selectedPlan: PlanChoice = .annual
    @State private var showingManageSubscriptions = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var annualPrice: String {
        proStore.annualProduct?.displayPrice ?? "$9.99"
    }

    private var lifetimePrice: String {
        proStore.lifetimeProduct?.displayPrice ?? "$29.99"
    }

    private var selectedProduct: Product? {
        switch selectedPlan {
        case .annual: proStore.annualProduct
        case .lifetime: proStore.lifetimeProduct
        }
    }

    private var showsAnnualTrialBadge: Bool {
        proStore.isAnnualTrialEligible || proStore.annualProduct?.subscription?.introductoryOffer != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    heroHeader
                    featuresCard
                    purchaseSection
                    legalFooter
                }
                .frame(maxWidth: ProDesign.Layout.readableHeroWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(theme.backgroundColor.ignoresSafeArea())
            .navigationTitle("AmberTTY Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if proStore.annualProduct == nil || proStore.lifetimeProduct == nil {
                    await proStore.loadProducts(reportErrors: false)
                }
            }
            .onDisappear {
                proStore.clearError()
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 12) {
            ProSquircleIcon(
                symbolName: "sparkles",
                tint: palette.proBrandAmber,
                size: .hero,
                emphasis: .hero,
                theme: theme
            )

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("AmberTTY Pro")
                        .font(.title2.bold())
                        .foregroundStyle(theme.foregroundColor)

                    if showsAnnualTrialBadge && !proStore.isPurchased {
                        Text("7-Day Free Trial")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(palette.proBrandAmber)
                            .background(palette.badgeFill(for: palette.proBrandAmber), in: Capsule())
                    }
                }

                Text("Start with a 7-day free trial or unlock lifetime access. Core SSH terminal, keys, snippets, and iCloud sync stay free forever.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "sparkles",
                tint: palette.proBrandAmber,
                title: "AI Agent Sessions",
                subtitle: "Launch & reattach Claude Code, agy, Codex & custom CLIs in persistent tmux sessions with Prompt Composer, Photo Attach, Git Diff, Dev Server Preview & alerts."
            )

            Divider()

            featureRow(
                icon: "folder.fill",
                tint: .blue,
                title: "SFTP File Browser",
                subtitle: "Browse remote directories, preview code and logs, upload, download, rename, and delete files."
            )

            Divider()

            featureRow(
                icon: "arrow.left.arrow.right",
                tint: palette.healthy,
                title: "Local Port Forwarding",
                subtitle: "Create -L tunnels to localhost with auto-start rules and 1-tap Open in Safari."
            )

            Divider()

            featureRow(
                icon: "cloud.fill",
                tint: palette.running,
                title: "DigitalOcean & Cloudflare",
                subtitle: "Manage Droplets, 1-tap SSH, sync hosts, edit DNS records, and inspect Zero Trust Tunnels."
            )
        }
        .padding(18)
        .proSurfaceCard(theme: theme)
    }

    private func featureRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ProSquircleIcon(
                symbolName: icon,
                tint: tint,
                size: .row,
                emphasis: .standard,
                theme: theme
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.foregroundColor)

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
                purchasedCard
            } else {
                if proStore.isTestFlight {
                    testFlightNotice("Pro features are unlocked for TestFlight testers.")
                } else {
                    #if DEBUG
                    testFlightNotice("Pro features are unlocked in Debug builds.")
                    #endif
                }

                planSelector

                if let errorMessage = proStore.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(palette.critical)
                        .multilineTextAlignment(.center)
                }

                Button {
                    AppHaptics.impact(.light)
                    let product = selectedProduct
                    let productID = selectedPlan.productID
                    Task {
                        if let product {
                            await proStore.purchase(product)
                        } else {
                            await proStore.purchase(productID: productID)
                        }
                    }
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
                .tint(palette.proBrandAmber)
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

                Text(disclosureText)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var purchasedCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(palette.healthy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.purchasedTitle(for: proStore.activePlan))
                        .font(.headline)
                        .foregroundStyle(theme.foregroundColor)
                    Text(Self.purchasedSubtitle(for: proStore.activePlan))
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)
            .background(
                palette.healthy.opacity(theme.isDark ? 0.14 : 0.10),
                in: RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
                    .strokeBorder(palette.healthy.opacity(0.40), lineWidth: 1)
            )

            if case .annual = proStore.activePlan {
                Button {
                    AppHaptics.impact(.light)
                    showingManageSubscriptions = true
                } label: {
                    Text("Manage Subscription")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var planSelector: some View {
        VStack(spacing: 10) {
            planCard(
                plan: .annual,
                title: "Annual",
                badge: showsAnnualTrialBadge ? "7-Day Free Trial" : nil,
                prominentPrice: "\(annualPrice) / year",
                subtitle: Self.annualSubtitle(
                    annualPrice: annualPrice,
                    isTrialEligible: proStore.isAnnualTrialEligible
                )
            )

            planCard(
                plan: .lifetime,
                title: "Lifetime",
                badge: "Pay Once",
                prominentPrice: lifetimePrice,
                subtitle: "One-time purchase · Keep forever"
            )
        }
    }

    private func planCard(
        plan: PlanChoice,
        title: String,
        badge: String?,
        prominentPrice: String,
        subtitle: String
    ) -> some View {
        let isSelected = selectedPlan == plan

        return Button {
            guard selectedPlan != plan else { return }
            AppHaptics.impact(.light)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                selectedPlan = plan
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isSelected
                            ? palette.proBrandAmber
                            : theme.secondaryForegroundColor.opacity(0.55)
                    )
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(theme.foregroundColor)

                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(isSelected ? palette.proBrandAmber : theme.secondaryForegroundColor)
                                .background(
                                    isSelected
                                        ? palette.badgeFill(for: palette.proBrandAmber)
                                        : theme.secondaryForegroundColor.opacity(0.14),
                                    in: Capsule()
                                )
                        }
                    }

                    Text(prominentPrice)
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(theme.foregroundColor)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? palette.proBrandAmber.opacity(theme.isDark ? 0.14 : 0.10) : palette.cardFill,
                in: RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? palette.proBrandAmber : palette.borderSubtle,
                        lineWidth: isSelected ? 1.75 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var purchaseButtonTitle: String {
        if proStore.isLoading {
            return "Loading…"
        }
        return Self.primaryCTATitle(
            for: selectedPlan,
            annualPrice: annualPrice,
            lifetimePrice: lifetimePrice,
            isTrialEligible: proStore.isAnnualTrialEligible
        )
    }

    private var disclosureText: String {
        Self.disclosureText(
            for: selectedPlan,
            annualPrice: annualPrice,
            isTrialEligible: proStore.isAnnualTrialEligible
        )
    }

    nonisolated static func annualSubtitle(annualPrice: String, isTrialEligible: Bool) -> String {
        isTrialEligible ? "7 days free, then \(annualPrice)/year" : "Billed annually"
    }

    nonisolated static func primaryCTATitle(
        for plan: PlanChoice,
        annualPrice: String,
        lifetimePrice: String,
        isTrialEligible: Bool
    ) -> String {
        switch plan {
        case .annual:
            isTrialEligible ? "Start 7-Day Free Trial" : "Subscribe — \(annualPrice)/year"
        case .lifetime:
            "Unlock Lifetime — \(lifetimePrice)"
        }
    }

    nonisolated static func disclosureText(
        for plan: PlanChoice,
        annualPrice: String,
        isTrialEligible: Bool
    ) -> String {
        switch plan {
        case .annual:
            if isTrialEligible {
                return "After the 7-day free trial, your subscription automatically renews at \(annualPrice)/year unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in App Store Account Settings."
            }
            return "Your subscription automatically renews at \(annualPrice)/year unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in App Store Account Settings."
        case .lifetime:
            return "One-time purchase. No recurring subscription."
        }
    }

    nonisolated static func purchasedTitle(for plan: ProStore.ActivePlan) -> String {
        switch plan {
        case .lifetime: "Pro Unlocked (Lifetime)"
        case .annual: "Pro Unlocked (Annual)"
        case .none: "Pro Unlocked"
        }
    }

    nonisolated static func purchasedSubtitle(for plan: ProStore.ActivePlan) -> String {
        switch plan {
        case .lifetime:
            "One-time purchase · Thank you for supporting AmberTTY."
        case .annual(let expirationDate):
            if let expirationDate {
                "Renews \(expirationDate.formatted(date: .abbreviated, time: .omitted)) · Thank you for supporting AmberTTY."
            } else {
                "Active annual subscription · Thank you for supporting AmberTTY."
            }
        case .none:
            "Thank you for supporting AmberTTY."
        }
    }

    private func testFlightNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.healthy)
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.foregroundColor)
            Spacer()
        }
        .padding(12)
        .background(
            palette.healthy.opacity(theme.isDark ? 0.12 : 0.09),
            in: RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous)
                .strokeBorder(palette.healthy.opacity(0.32), lineWidth: 1)
        )
    }

    private var legalFooter: some View {
        HStack(spacing: 8) {
            if let privacyURL = URL(string: "https://github.com/peculiarengineer-mk/term-app/blob/main/PRIVACY.md") {
                Link("Privacy Policy", destination: privacyURL)
            }

            Text("·")
                .accessibilityHidden(true)

            if let termsURL = URL(string: "https://github.com/peculiarengineer-mk/term-app/blob/main/TERMS.md") {
                Link("Terms of Use", destination: termsURL)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
        .tint(theme.secondaryForegroundColor)
        .padding(.top, 2)
    }
}
