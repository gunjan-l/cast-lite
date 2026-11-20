import Foundation

/// Tabs the app can show. Only `AppShell.visibleTabs` are reachable in v1.
public enum AppTab: Hashable, Sendable {
    case mirror
    case cast
    case settings
}

/// v1 scope: mirror only. Cast tab, paywall and premium entry points stay in the
/// build but are not reachable.
public enum AppShell {
    public static let visibleTabs: [AppTab] = [.mirror, .settings]
    public static let showsPaywall = false
    public static let showsPremiumEntryPoints = false
    public static let requiresEntitlementToMirror = false
}

public enum SelectionChange: Equatable, Sendable {
    case changed
    case unchanged
}

/// Records which TV the user picked. Selecting never starts mirroring.
public struct DeviceSelection: Sendable {
    public private(set) var device: DiscoveredDevice?

    public init(device: DiscoveredDevice? = nil) {
        self.device = device
    }

    @discardableResult
    public mutating func select(_ newDevice: DiscoveredDevice?) -> SelectionChange {
        guard newDevice?.id != device?.id else { return .unchanged }
        device = newDevice
        return .changed
    }
}
