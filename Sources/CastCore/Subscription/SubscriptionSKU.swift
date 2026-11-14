import Foundation

public enum SubscriptionSKU: String, CaseIterable, Sendable, Equatable {
    case weekly = "com.castlite.subscription.weekly"
    case annual = "com.castlite.subscription.annual"
    case lifetime = "com.castlite.lifetime"

    public var identifier: String {
        return self.rawValue
    }

    public var displayName: String {
        switch self {
        case .weekly:
            return "Weekly with 3-Day Free Trial"
        case .annual:
            return "Annual Best Value (Save 84%)"
        case .lifetime:
            return "Lifetime Access"
        }
    }

    public var priceDescription: String {
        switch self {
        case .weekly:
            return "$4.99/week"
        case .annual:
            return "$39.99/year ($0.77/week)"
        case .lifetime:
            return "$59.99 one-time"
        }
    }

    public var subtitle: String {
        switch self {
        case .weekly:
            return "3 days free, then $4.99/wk. Cancel anytime."
        case .annual:
            return "Billed annually. Most popular choice."
        case .lifetime:
            return "Pay once, own forever. No subscription."
        }
    }
}

public enum EntitlementStatus: Sendable, Equatable {
    case inactive
    case trial(daysRemaining: Int)
    case active(sku: SubscriptionSKU, expiresDate: Date?)
    case lifetime

    public var isEntitled: Bool {
        switch self {
        case .inactive:
            return false
        case .trial, .active, .lifetime:
            return true
        }
    }

    public var description: String {
        switch self {
        case .inactive:
            return "Free Tier"
        case .trial(let days):
            return "Free Trial (\(days) days remaining)"
        case .active(let sku, _):
            return "Active (\(sku.displayName))"
        case .lifetime:
            return "Lifetime Premium"
        }
    }
}
