import Foundation
import Observation
import StoreKit

/// Manages StoreKit 2 entitlements and purchases for TermApp Pro (Annual subscription and Lifetime unlock).
@MainActor @Observable
final class ProStore {
    nonisolated static let annualProductID = "com.peculiarengineer.termapp.pro.annual"
    nonisolated static let lifetimeProductID = "com.peculiarengineer.termapp.pro"
    nonisolated static let proProductID = lifetimeProductID
    nonisolated static let allProductIDs = [annualProductID, lifetimeProductID]

    enum ActivePlan: Equatable, Sendable {
        case none
        case annual(expirationDate: Date?)
        case lifetime
    }

    struct EntitlementCandidate: Equatable, Sendable {
        let productID: String
        let revocationDate: Date?
        let expirationDate: Date?
    }

    private(set) var annualProduct: Product?
    private(set) var lifetimeProduct: Product?
    private(set) var isAnnualTrialEligible = false
    private(set) var activePlan: ActivePlan = .none
    private(set) var isTestFlight = false
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var errorMessage: String?

    var isPurchased: Bool {
        activePlan != .none
    }

    var product: Product? {
        lifetimeProduct ?? annualProduct
    }

    var isLoading: Bool {
        isPurchasing || isRestoring
    }

    @ObservationIgnored
    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    @ObservationIgnored
    private var isRefreshingEnvironment = false

    var isProUnlocked: Bool {
        if isPurchased { return true }
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }

    init() {
        updatesTask = observeTransactionUpdates()
        Task { [weak self] in
            await self?.loadInitialState()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts(reportErrors: Bool = true) async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        if reportErrors { errorMessage = nil }
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: Self.allProductIDs)
            annualProduct = products.first { $0.id == Self.annualProductID }
            lifetimeProduct = products.first { $0.id == Self.lifetimeProductID }
            await refreshTrialEligibility()
        } catch {
            if reportErrors {
                errorMessage = "Could not load App Store products: \(error.localizedDescription)"
            }
        }
    }

    func refreshAppEnvironment() async {
        guard !isRefreshingEnvironment else { return }
        isRefreshingEnvironment = true
        defer { isRefreshingEnvironment = false }

        if case .verified(let tx) = try? await AppTransaction.shared {
            isTestFlight = (tx.environment == .sandbox)
        } else {
            isTestFlight = false
        }
    }

    func refreshEntitlements() async {
        await refreshAppEnvironment()
        var candidates: [EntitlementCandidate] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            candidates.append(
                EntitlementCandidate(
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate,
                    expirationDate: transaction.expirationDate
                )
            )
        }
        activePlan = Self.resolveActivePlan(from: candidates)
        await refreshTrialEligibility()
    }

    nonisolated static func resolveActivePlan(
        from candidates: [EntitlementCandidate],
        now: Date = Date()
    ) -> ActivePlan {
        var resolved: ActivePlan = .none
        for candidate in candidates {
            guard candidate.revocationDate == nil else { continue }
            if candidate.productID == lifetimeProductID {
                return .lifetime
            }
            if candidate.productID == annualProductID {
                if let expirationDate = candidate.expirationDate, expirationDate <= now {
                    continue
                }
                switch resolved {
                case .none:
                    resolved = .annual(expirationDate: candidate.expirationDate)
                case .annual(let existingExpiration):
                    if let newExpiration = candidate.expirationDate,
                       existingExpiration.map({ newExpiration > $0 }) ?? true {
                        resolved = .annual(expirationDate: newExpiration)
                    }
                case .lifetime:
                    return .lifetime
                }
            }
        }
        return resolved
    }

    func purchase(_ product: Product) async {
        guard !isLoading else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        await performPurchase(product)
    }

    func purchase(productID: String) async {
        guard !isLoading else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        if let cached = cachedProduct(for: productID) {
            await performPurchase(cached)
            return
        }

        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            annualProduct = loaded.first { $0.id == Self.annualProductID } ?? annualProduct
            lifetimeProduct = loaded.first { $0.id == Self.lifetimeProductID } ?? lifetimeProduct
            await refreshTrialEligibility()
            guard let target = cachedProduct(for: productID) else {
                errorMessage = "TermApp Pro is currently unavailable. Please try again later."
                return
            }
            await performPurchase(target)
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            AppHaptics.notify(.error)
        }
    }

    func restorePurchases() async {
        guard !isLoading else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isPurchased {
                AppHaptics.notify(.success)
            } else {
                errorMessage = "No previous TermApp Pro purchase was found."
            }
        } catch {
            errorMessage = "Could not restore purchases: \(error.localizedDescription)"
            AppHaptics.notify(.error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func cachedProduct(for productID: String) -> Product? {
        switch productID {
        case Self.annualProductID: annualProduct
        case Self.lifetimeProductID: lifetimeProduct
        default: nil
        }
    }

    private func performPurchase(_ targetProduct: Product) async {
        do {
            let result = try await targetProduct.purchase()
            switch result {
            case .success(let verification):
                await handle(verificationResult: verification, reportUnverifiedError: true)
                if isPurchased {
                    AppHaptics.notify(.success)
                }
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            AppHaptics.notify(.error)
        }
    }

    private func refreshTrialEligibility() async {
        guard let subscription = annualProduct?.subscription else {
            isAnnualTrialEligible = false
            return
        }
        isAnnualTrialEligible = await subscription.isEligibleForIntroOffer
    }

    private func loadInitialState() async {
        await refreshEntitlements()
        await loadProducts(reportErrors: false)
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.handle(verificationResult: result, reportUnverifiedError: false)
            }
        }
    }

    private func handle(
        verificationResult: VerificationResult<StoreKit.Transaction>,
        reportUnverifiedError: Bool
    ) async {
        switch verificationResult {
        case .verified(let transaction):
            guard Self.allProductIDs.contains(transaction.productID) else { return }
            await transaction.finish()
            await refreshEntitlements()
        case .unverified(_, let error):
            if reportUnverifiedError {
                errorMessage = "Purchase could not be verified: \(error.localizedDescription)"
            }
        }
    }
}
