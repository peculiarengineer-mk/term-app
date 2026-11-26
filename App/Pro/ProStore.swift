import Foundation
import Observation
import StoreKit

/// Manages StoreKit 2 entitlements and purchases for the one-time TermApp Pro unlock.
@MainActor @Observable
final class ProStore {
    static let productID = "com.peculiarengineer.termapp.pro"

    private(set) var product: Product?
    private(set) var isPurchased = false
    private(set) var isTestFlight = false
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var errorMessage: String?

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
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            if reportErrors {
                errorMessage = "Could not load App Store product: \(error.localizedDescription)"
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
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.productID && transaction.revocationDate == nil {
                entitled = true
                break
            }
        }
        isPurchased = entitled
    }

    func purchase() async {
        guard !isLoading else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let targetProduct: Product
            if let existing = product {
                targetProduct = existing
            } else {
                let loaded = try await Product.products(for: [Self.productID])
                product = loaded.first
                guard let first = loaded.first else {
                    errorMessage = "TermApp Pro is currently unavailable. Please try again later."
                    return
                }
                targetProduct = first
            }

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
            guard transaction.productID == Self.productID else { return }
            await transaction.finish()
            await refreshEntitlements()
        case .unverified(_, let error):
            if reportUnverifiedError {
                errorMessage = "Purchase could not be verified: \(error.localizedDescription)"
            }
        }
    }
}
