import Foundation
import SwiftUI
import TermUI
import UIKit
import XCTest
@testable import TermApp

final class ProStoreTests: XCTestCase {
    func testProductIdentifiersAndAliases() {
        XCTAssertEqual(ProStore.annualProductID, "com.peculiarengineer.termapp.pro.annual")
        XCTAssertEqual(ProStore.lifetimeProductID, "com.peculiarengineer.termapp.pro")
        XCTAssertEqual(ProStore.proProductID, ProStore.lifetimeProductID)
        XCTAssertEqual(ProStore.allProductIDs, [ProStore.annualProductID, ProStore.lifetimeProductID])
    }

    func testResolveActivePlanPrefersLifetimeAndIgnoresRevokedOrExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(86_400 * 30)
        let past = now.addingTimeInterval(-60)

        XCTAssertEqual(ProStore.resolveActivePlan(from: [], now: now), .none)

        let unknown = [
            ProStore.EntitlementCandidate(
                productID: "com.example.other",
                revocationDate: nil,
                expirationDate: future
            )
        ]
        XCTAssertEqual(ProStore.resolveActivePlan(from: unknown, now: now), .none)

        let expiredAnnual = [
            ProStore.EntitlementCandidate(
                productID: ProStore.annualProductID,
                revocationDate: nil,
                expirationDate: past
            )
        ]
        XCTAssertEqual(ProStore.resolveActivePlan(from: expiredAnnual, now: now), .none)

        let revokedLifetime = [
            ProStore.EntitlementCandidate(
                productID: ProStore.lifetimeProductID,
                revocationDate: past,
                expirationDate: nil
            )
        ]
        XCTAssertEqual(ProStore.resolveActivePlan(from: revokedLifetime, now: now), .none)

        let validAnnual = [
            ProStore.EntitlementCandidate(
                productID: ProStore.annualProductID,
                revocationDate: nil,
                expirationDate: future
            )
        ]
        XCTAssertEqual(
            ProStore.resolveActivePlan(from: validAnnual, now: now),
            .annual(expirationDate: future)
        )

        let annualThenLifetime = [
            ProStore.EntitlementCandidate(
                productID: ProStore.annualProductID,
                revocationDate: nil,
                expirationDate: future
            ),
            ProStore.EntitlementCandidate(
                productID: ProStore.lifetimeProductID,
                revocationDate: nil,
                expirationDate: nil
            ),
        ]
        XCTAssertEqual(ProStore.resolveActivePlan(from: annualThenLifetime, now: now), .lifetime)

        let revokedLifetimeWithAnnual = [
            ProStore.EntitlementCandidate(
                productID: ProStore.lifetimeProductID,
                revocationDate: past,
                expirationDate: nil
            ),
            ProStore.EntitlementCandidate(
                productID: ProStore.annualProductID,
                revocationDate: nil,
                expirationDate: future
            ),
        ]
        XCTAssertEqual(
            ProStore.resolveActivePlan(from: revokedLifetimeWithAnnual, now: now),
            .annual(expirationDate: future)
        )
    }

    @MainActor
    func testInitialProStoreState() {
        let store = ProStore()
        XCTAssertEqual(store.activePlan, .none)
        XCTAssertFalse(store.isPurchased)
        XCTAssertFalse(store.isAnnualTrialEligible)
        XCTAssertNil(store.annualProduct)
        XCTAssertNil(store.lifetimeProduct)
        XCTAssertNil(store.product)
    }

    func testPaywallCopyCompliance() {
        XCTAssertTrue(ProPaywallView.showsAnnualTrialBadge(isTrialEligible: true))
        XCTAssertFalse(ProPaywallView.showsAnnualTrialBadge(isTrialEligible: false))

        XCTAssertTrue(
            ProPaywallView.heroSubtitle(isTrialEligible: true).contains("7-day free trial")
        )
        XCTAssertFalse(
            ProPaywallView.heroSubtitle(isTrialEligible: false).localizedCaseInsensitiveContains("trial")
        )

        XCTAssertEqual(
            ProPaywallView.annualSubtitle(annualPrice: "$9.99", isTrialEligible: true),
            "7 days free, then $9.99/year"
        )
        XCTAssertEqual(
            ProPaywallView.annualSubtitle(annualPrice: "$9.99", isTrialEligible: false),
            "Billed annually"
        )

        XCTAssertEqual(
            ProPaywallView.purchaseButtonTitle(
                for: .annual,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: false,
                isLoading: true,
                isLoadingProducts: false,
                annualProductLoaded: false
            ),
            "Loading plans…"
        )
        XCTAssertEqual(
            ProPaywallView.purchaseButtonTitle(
                for: .annual,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: false,
                isLoading: false,
                isLoadingProducts: true,
                annualProductLoaded: false
            ),
            "Loading plans…"
        )
        XCTAssertEqual(
            ProPaywallView.purchaseButtonTitle(
                for: .annual,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: true,
                isLoading: true,
                isLoadingProducts: false,
                annualProductLoaded: true
            ),
            "Loading…"
        )

        XCTAssertEqual(
            ProPaywallView.primaryCTATitle(
                for: .annual,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: true
            ),
            "Start 7-Day Free Trial"
        )
        XCTAssertEqual(
            ProPaywallView.primaryCTATitle(
                for: .annual,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: false
            ),
            "Subscribe — $9.99/year"
        )
        XCTAssertEqual(
            ProPaywallView.primaryCTATitle(
                for: .lifetime,
                annualPrice: "$9.99",
                lifetimePrice: "$29.99",
                isTrialEligible: true
            ),
            "Unlock Lifetime — $29.99"
        )

        XCTAssertEqual(
            ProPaywallView.disclosureText(for: .annual, annualPrice: "$9.99", isTrialEligible: true),
            "After the 7-day free trial, your subscription automatically renews at $9.99/year unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in App Store Account Settings."
        )
        XCTAssertEqual(
            ProPaywallView.disclosureText(for: .annual, annualPrice: "$9.99", isTrialEligible: false),
            "Your subscription automatically renews at $9.99/year unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in App Store Account Settings."
        )
        XCTAssertEqual(
            ProPaywallView.disclosureText(for: .lifetime, annualPrice: "$9.99", isTrialEligible: true),
            "One-time purchase. No recurring subscription."
        )

        XCTAssertEqual(ProPaywallView.purchasedTitle(for: .lifetime), "Pro Unlocked (Lifetime)")
        XCTAssertEqual(ProPaywallView.purchasedTitle(for: .annual(expirationDate: nil)), "Pro Unlocked (Annual)")
        XCTAssertEqual(
            ProPaywallView.purchasedSubtitle(for: .lifetime),
            "One-time purchase · Thank you for supporting AmberTTY."
        )
        XCTAssertEqual(
            ProPaywallView.purchasedSubtitle(for: .annual(expirationDate: nil)),
            "Active annual subscription · Thank you for supporting AmberTTY."
        )
        XCTAssertEqual(
            ProPaywallView.purchasedSubtitle(for: .none),
            "Thank you for supporting AmberTTY."
        )
    }

    func testSettingsProStatusAndPriceFormatting() {
        XCTAssertEqual(
            SettingsView.proStatusTitle(for: .lifetime, isTestFlight: false, isDebugBuild: false),
            "Pro Unlocked (Lifetime)"
        )
        XCTAssertEqual(
            SettingsView.proStatusTitle(for: .annual(expirationDate: nil), isTestFlight: false, isDebugBuild: false),
            "Pro Unlocked (Annual)"
        )
        XCTAssertEqual(
            SettingsView.proStatusTitle(for: .none, isTestFlight: true, isDebugBuild: false),
            "Pro Unlocked (TestFlight)"
        )
        XCTAssertEqual(
            SettingsView.proStatusTitle(for: .none, isTestFlight: false, isDebugBuild: true),
            "Pro Unlocked (Debug)"
        )
        XCTAssertEqual(
            SettingsView.proStatusTitle(for: .none, isTestFlight: false, isDebugBuild: false),
            "Upgrade to Pro"
        )

        XCTAssertEqual(
            SettingsView.proTrailingPriceText(annualDisplayPrice: "$9.99", lifetimeDisplayPrice: "$29.99"),
            "From $9.99/yr"
        )
        XCTAssertEqual(
            SettingsView.proTrailingPriceText(annualDisplayPrice: nil, lifetimeDisplayPrice: "$29.99"),
            "$29.99"
        )
        XCTAssertEqual(
            SettingsView.proTrailingPriceText(annualDisplayPrice: nil, lifetimeDisplayPrice: nil),
            "From $9.99/yr"
        )
    }

    func testProPaletteWCAGContrastAcrossDarkAndLightThemes() throws {
        let darkPalette = ProDesign.Palette(theme: .appleProDark)
        let lightPalette = ProDesign.Palette(theme: .light)

        let darkAmber = try rgbComponents(of: darkPalette.proBrandAmber)
        let darkInk = try rgbComponents(of: darkPalette.proBrandAmberButtonInk)
        let darkBackground = TerminalTheme.appleProDark.background
        XCTAssertGreaterThanOrEqual(darkAmber.contrastRatio(with: darkBackground), 4.5)
        XCTAssertGreaterThanOrEqual(darkAmber.contrastRatio(with: darkInk), 9.0)

        let lightAmber = try rgbComponents(of: lightPalette.proBrandAmber)
        let lightWarning = try rgbComponents(of: lightPalette.warning)
        let lightInk = try rgbComponents(of: lightPalette.proBrandAmberButtonInk)
        let lightBackground = TerminalTheme.light.background
        XCTAssertEqual(lightAmber, lightWarning)
        XCTAssertGreaterThanOrEqual(lightAmber.contrastRatio(with: lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(lightAmber.contrastRatio(with: lightInk), 4.5)
    }

    private func rgbComponents(of color: SwiftUI.Color) throws -> TerminalTheme.RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = UIColor(color)
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
        return TerminalTheme.RGB(
            UInt8((r * 255).rounded()),
            UInt8((g * 255).rounded()),
            UInt8((b * 255).rounded())
        )
    }
}
