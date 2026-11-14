import XCTest
import Foundation
@testable import CastCore

final class SubscriptionManagerTests: XCTestCase {

    func testInitialEntitlementStateIsInactive() async {
        let manager = SubscriptionManager(mockInitialState: .inactive)
        let status = await manager.status
        let isEntitled = await manager.isEntitled

        XCTAssertEqual(status, .inactive)
        XCTAssertFalse(isEntitled)
    }

    func testTrialEntitlementStateIsEntitled() async {
        let manager = SubscriptionManager(mockInitialState: .trial(daysRemaining: 3))
        let isEntitled = await manager.isEntitled
        let status = await manager.status

        XCTAssertTrue(isEntitled)
        XCTAssertEqual(status, .trial(daysRemaining: 3))
    }

    func testActiveSubscriptionEntitlement() async {
        let expiry = Date().addingTimeInterval(86400 * 30)
        let manager = SubscriptionManager(mockInitialState: .active(sku: .annual, expiresDate: expiry))
        let isEntitled = await manager.isEntitled

        XCTAssertTrue(isEntitled)
        let status = await manager.status
        XCTAssertEqual(status, .active(sku: .annual, expiresDate: expiry))
    }

    func testLifetimeEntitlement() async {
        let manager = SubscriptionManager(mockInitialState: .lifetime)
        let isEntitled = await manager.isEntitled

        XCTAssertTrue(isEntitled)
        let status = await manager.status
        XCTAssertEqual(status, .lifetime)
    }

    func testSimulatePurchaseTransitionsEntitlement() async throws {
        let manager = SubscriptionManager(mockInitialState: .inactive)
        var isEntitled = await manager.isEntitled
        XCTAssertFalse(isEntitled)

        let newStatus = try await manager.mockPurchase(sku: .weekly)
        XCTAssertEqual(newStatus, .trial(daysRemaining: 3))

        isEntitled = await manager.isEntitled
        XCTAssertTrue(isEntitled)
    }

    func testSimulateRestorePurchases() async throws {
        let manager = SubscriptionManager(mockInitialState: .inactive)
        let restoredStatus = try await manager.mockRestore(entitlement: .lifetime)

        XCTAssertEqual(restoredStatus, .lifetime)
        let isEntitled = await manager.isEntitled
        XCTAssertTrue(isEntitled)
    }

    func testStoreKitConfigurationValidation() {
        // Verify SKU identifiers match App Store specifications
        XCTAssertEqual(SubscriptionSKU.weekly.identifier, "com.castlite.subscription.weekly")
        XCTAssertEqual(SubscriptionSKU.annual.identifier, "com.castlite.subscription.annual")
        XCTAssertEqual(SubscriptionSKU.lifetime.identifier, "com.castlite.lifetime")
    }
}
