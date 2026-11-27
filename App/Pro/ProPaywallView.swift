import SwiftUI
import StoreKit
import TermUI

/// Apple Pro sheet presenting the hybrid AmberTTY Pro Annual subscription and Lifetime purchase.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
        Self.showsAnnualTrialBadge(isTrialEligible: proStore.isAnnualTrialEligible)
    }

    private var isFetchingInitialPlans: Bool {
        (proStore.isLoading || proStore.isLoadingProducts) && proStore.annualProduct == nil
    }

    private var shouldPinBottomDock: Bool {
        !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroHeader
                    featuresCard

                    if proStore.isPurchased {
                        purchasedCard
                    } else {
                        testFlightBanner

                        Text(disclosureText)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !shouldPinBottomDock {
                        dockContent
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: ProDesign.Layout.readableHeroWidth)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldPinBottomDock {
                    frostedBottomDock
                }
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
        .tint(palette.proBrandAmber)
    }

    private var heroHeader: some View {
        VStack(spacing: 10) {
            ProSquircleIcon(
                symbolName: "sparkles",
                tint: palette.proBrandAmber,
                size: .hero,
                emphasis: .hero,
                theme: theme
            )

            VStack(spacing: 6) {
                heroTitleRow

                Text(Self.heroSubtitle(isTrialEligible: showsAnnualTrialBadge))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var heroTitleRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                Text("AmberTTY Pro")
                    .font(.title2.bold())
                    .foregroundStyle(theme.foregroundColor)
                trialPillBadge
            }
        } else {
            HStack(spacing: 8) {
                Text("AmberTTY Pro")
                    .font(.title2.bold())
                    .foregroundStyle(theme.foregroundColor)
                trialPillBadge
            }
        }
    }

    @ViewBuilder
    private var trialPillBadge: some View {
        if showsAnnualTrialBadge && !proStore.isPurchased {
            Text("7-Day Free Trial")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(palette.proBrandAmber)
                .background(palette.badgeFill(for: palette.proBrandAmber), in: Capsule())
        }
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(
                icon: "sparkles",
                tint: palette.proBrandAmber,
                title: "AI Agent Sessions",
                subtitle: "Run Claude Code, Antigravity & Codex in tmux with diffs, previews & alerts."
            )

            Divider()

            featureRow(
                icon: "folder.fill",
                tint: .blue,
                title: "SFTP File Browser",
                subtitle: "Browse directories, preview code and logs, and transfer or manage remote files."
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
                subtitle: "Manage Droplets, 1-tap SSH, host sync, DNS records, and Zero Trust Tunnels."
            )
        }
        .padding(16)
        .proSurfaceCard(theme: theme)
    }

    @ViewBuilder
    private func featureRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                ProSquircleIcon(
                    symbolName: icon,
                    tint: tint,
                    size: .row,
                    emphasis: .standard,
                    theme: theme
                )
                featureRowText(title: title, subtitle: subtitle)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ProSquircleIcon(
                    symbolName: icon,
                    tint: tint,
                    size: .row,
                    emphasis: .standard,
                    theme: theme
                )
                featureRowText(title: title, subtitle: subtitle)
            }
        }
    }

    private func featureRowText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.foregroundColor)

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(theme.secondaryForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var frostedBottomDock: some View {
        dockContent
            .frame(maxWidth: ProDesign.Layout.readableHeroWidth)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    theme.backgroundColor.opacity(0.72)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 0.5)
            }
    }

    @ViewBuilder
    private var dockContent: some View {
        if proStore.isPurchased {
            legalFooter
        } else {
            VStack(spacing: 0) {
                planSelector

                if let errorMessage = proStore.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(palette.critical)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                primaryCTAButton
                    .padding(.top, 10)

                Text("No account required · Zero telemetry · Cancel anytime")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                dockFooterActions
            }
        }
    }

    private var primaryCTAButton: some View {
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
                if proStore.isLoading || isFetchingInitialPlans {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.proBrandAmberButtonInk)
                }
                Text(purchaseButtonTitle)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(palette.proBrandAmberButtonInk)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(palette.proBrandAmber)
        .disabled(proStore.isLoading)
    }

    private var restorePurchasesButton: some View {
        Button {
            AppHaptics.impact(.light)
            Task { await proStore.restorePurchases() }
        } label: {
            Text("Restore Purchases")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.proBrandAmber)
                .frame(minHeight: ProDesign.Layout.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(proStore.isLoading)
    }

    @ViewBuilder
    private var dockFooterActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                restorePurchasesButton
                legalFooter
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    restorePurchasesButton
                        .fixedSize()
                    footerSeparator
                    legalLinksHorizontal(fixedWidth: true)
                }
                .font(.caption)

                VStack(spacing: 0) {
                    restorePurchasesButton
                    legalFooter
                }
            }
        }
    }

    private var footerSeparator: some View {
        Text("·")
            .foregroundStyle(theme.secondaryForegroundColor)
            .accessibilityHidden(true)
    }

    private var purchasedCard: some View {
        VStack(spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        purchasedCardContent
                    }
                } else {
                    HStack(spacing: 12) {
                        purchasedCardContent
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var purchasedCardContent: some View {
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
    }

    private var planSelector: some View {
        VStack(spacing: 8) {
            planCard(
                plan: .annual,
                title: "Annual",
                badge: showsAnnualTrialBadge ? "7-Day Free Trial" : nil,
                prominentPrice: "\(annualPrice) / year",
                subtitle: Self.annualSubtitle(
                    annualPrice: annualPrice,
                    isTrialEligible: showsAnnualTrialBadge
                )
            )

            planCard(
                plan: .lifetime,
                title: "Lifetime",
                badge: "Best Value",
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
        let isBestValue = plan == .lifetime

        return Button {
            guard selectedPlan != plan else { return }
            AppHaptics.impact(.light)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                selectedPlan = plan
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isSelected
                            ? palette.proBrandAmber
                            : theme.secondaryForegroundColor.opacity(0.55)
                    )
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            planTitleAndBadge(title: title, badge: badge, isSelected: isSelected, isBestValue: isBestValue)
                            Text(prominentPrice)
                                .font(.headline.bold().monospacedDigit())
                                .foregroundStyle(theme.foregroundColor)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            planTitleAndBadge(title: title, badge: badge, isSelected: isSelected, isBestValue: isBestValue)
                            Spacer(minLength: 4)
                            Text(prominentPrice)
                                .font(.headline.bold().monospacedDigit())
                                .foregroundStyle(theme.foregroundColor)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

    private func planTitleAndBadge(
        title: String,
        badge: String?,
        isSelected: Bool,
        isBestValue: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.foregroundColor)

            if let badge {
                let highlightBadge = isSelected || isBestValue
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(highlightBadge ? palette.proBrandAmber : theme.secondaryForegroundColor)
                    .background(
                        highlightBadge
                            ? palette.badgeFill(for: palette.proBrandAmber)
                            : theme.secondaryForegroundColor.opacity(0.14),
                        in: Capsule()
                    )
            }
        }
    }

    private var purchaseButtonTitle: String {
        Self.purchaseButtonTitle(
            for: selectedPlan,
            annualPrice: annualPrice,
            lifetimePrice: lifetimePrice,
            isTrialEligible: proStore.isAnnualTrialEligible,
            isLoading: proStore.isLoading,
            isLoadingProducts: proStore.isLoadingProducts,
            annualProductLoaded: proStore.annualProduct != nil
        )
    }

    private var disclosureText: String {
        Self.disclosureText(
            for: selectedPlan,
            annualPrice: annualPrice,
            isTrialEligible: proStore.isAnnualTrialEligible
        )
    }

    nonisolated static func showsAnnualTrialBadge(isTrialEligible: Bool) -> Bool {
        isTrialEligible
    }

    nonisolated static func heroSubtitle(isTrialEligible: Bool) -> String {
        if isTrialEligible {
            return "Start with a 7-day free trial or unlock lifetime access. Core SSH terminal, keys, snippets, and iCloud sync stay free forever."
        }
        return "Choose an annual subscription or one-time lifetime unlock. Core SSH terminal, keys, snippets, and iCloud sync stay free forever."
    }

    nonisolated static func annualSubtitle(annualPrice: String, isTrialEligible: Bool) -> String {
        isTrialEligible ? "7 days free, then \(annualPrice)/year" : "Billed annually"
    }

    nonisolated static func purchaseButtonTitle(
        for plan: PlanChoice,
        annualPrice: String,
        lifetimePrice: String,
        isTrialEligible: Bool,
        isLoading: Bool,
        isLoadingProducts: Bool,
        annualProductLoaded: Bool
    ) -> String {
        if (isLoading || isLoadingProducts) && !annualProductLoaded {
            return "Loading plans…"
        }
        if isLoading {
            return "Loading…"
        }
        return primaryCTATitle(
            for: plan,
            annualPrice: annualPrice,
            lifetimePrice: lifetimePrice,
            isTrialEligible: isTrialEligible
        )
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

    @ViewBuilder
    private var testFlightBanner: some View {
        if proStore.isTestFlight {
            testFlightNotice("Pro features are unlocked for TestFlight testers.")
        } else {
            #if DEBUG
            testFlightNotice("Pro features are unlocked in Debug builds.")
            #endif
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

    @ViewBuilder
    private var legalFooter: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                legalLinksContent(fixedWidth: false)
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .tint(theme.secondaryForegroundColor)
        } else {
            legalLinksHorizontal(fixedWidth: false)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .tint(theme.secondaryForegroundColor)
        }
    }

    private func legalLinksHorizontal(fixedWidth: Bool) -> some View {
        HStack(spacing: 8) {
            if let privacyURL = URL(string: "https://github.com/peculiarengineer-mk/ambertty/blob/main/PRIVACY.md") {
                legalLink("Privacy Policy", destination: privacyURL, fixedWidth: fixedWidth)
            }

            footerSeparator

            if let termsURL = URL(string: "https://github.com/peculiarengineer-mk/ambertty/blob/main/TERMS.md") {
                legalLink("Terms of Use", destination: termsURL, fixedWidth: fixedWidth)
            }
        }
    }

    @ViewBuilder
    private func legalLinksContent(fixedWidth: Bool) -> some View {
        if let privacyURL = URL(string: "https://github.com/peculiarengineer-mk/ambertty/blob/main/PRIVACY.md") {
            legalLink("Privacy Policy", destination: privacyURL, fixedWidth: fixedWidth)
        }

        if let termsURL = URL(string: "https://github.com/peculiarengineer-mk/ambertty/blob/main/TERMS.md") {
            legalLink("Terms of Use", destination: termsURL, fixedWidth: fixedWidth)
        }
    }

    @ViewBuilder
    private func legalLink(_ title: String, destination: URL, fixedWidth: Bool) -> some View {
        let link = Link(title, destination: destination)
            .foregroundStyle(theme.secondaryForegroundColor)
            .tint(theme.secondaryForegroundColor)
            .frame(minHeight: ProDesign.Layout.minTapTarget)
            .contentShape(Rectangle())
        if fixedWidth {
            link.fixedSize()
        } else {
            link
        }
    }
}
