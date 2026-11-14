import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

public actor SubscriptionManager {
    public private(set) var status: EntitlementStatus
    public var isEntitled: Bool { status.isEntitled }

    public init(mockInitialState: EntitlementStatus = .inactive) {
        self.status = mockInitialState
        #if canImport(StoreKit)
        Task {
            await listenForStoreKitUpdates()
            await refreshEntitlements()
        }
        #endif
    }

    public func mockPurchase(sku: SubscriptionSKU) async throws -> EntitlementStatus {
        switch sku {
        case .weekly:
            self.status = .trial(daysRemaining: 3)
        case .annual:
            let expiry = Date().addingTimeInterval(86400 * 365)
            self.status = .active(sku: .annual, expiresDate: expiry)
        case .lifetime:
            self.status = .lifetime
        }
        return self.status
    }

    public func mockRestore(entitlement: EntitlementStatus) async throws -> EntitlementStatus {
        self.status = entitlement
        return self.status
    }

    #if canImport(StoreKit)
    public func purchase(product: Product) async throws -> EntitlementStatus {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
            return self.status
        case .userCancelled, .pending:
            return self.status
        @unknown default:
            return self.status
        }
    }

    public func restorePurchases() async throws -> EntitlementStatus {
        try await AppStore.sync()
        await refreshEntitlements()
        return self.status
    }

    public func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.revocationDate == nil {
                if transaction.productID == SubscriptionSKU.lifetime.identifier {
                    self.status = .lifetime
                    return
                } else if transaction.productID == SubscriptionSKU.annual.identifier {
                    self.status = .active(sku: .annual, expiresDate: transaction.expirationDate)
                    return
                } else if transaction.productID == SubscriptionSKU.weekly.identifier {
                    if transaction.offerType == .introductory {
                        self.status = .trial(daysRemaining: 3)
                    } else {
                        self.status = .active(sku: .weekly, expiresDate: transaction.expirationDate)
                    }
                    return
                }
            }
        }
        self.status = .inactive
    }

    private func listenForStoreKitUpdates() {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { break }
                if let transaction = try? self.checkVerified(result) {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.networkError(URLError(.cannotDecodeRawData))
        case .verified(let safe):
            return safe
        }
    }
    #endif
}
