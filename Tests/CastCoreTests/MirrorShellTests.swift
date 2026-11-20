import XCTest
@testable import CastCore

final class MirrorShellTests: XCTestCase {
    private func device(_ id: String) -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: "TV \(id)", type: .chromecast, ipAddress: "192.168.1.5", port: 8009)
    }

    func testTabBarShowsOnlyMirrorAndSettings() {
        XCTAssertEqual(AppShell.visibleTabs, [.mirror, .settings])
    }

    func testPaywallAndPremiumEntryPointsAreHidden() {
        XCTAssertFalse(AppShell.showsPaywall)
        XCTAssertFalse(AppShell.showsPremiumEntryPoints)
        XCTAssertFalse(AppShell.requiresEntitlementToMirror)
    }

    func testSelectingDeviceOnlyRecordsSelection() {
        var selection = DeviceSelection()
        let change = selection.select(device("a"))
        XCTAssertEqual(selection.device?.id, "a")
        XCTAssertEqual(change, .changed)
    }

    func testReselectingSameDeviceIsNoOp() {
        var selection = DeviceSelection()
        _ = selection.select(device("a"))
        XCTAssertEqual(selection.select(device("a")), .unchanged)
    }

    func testSwitchingAndClearingSelection() {
        var selection = DeviceSelection()
        _ = selection.select(device("a"))
        XCTAssertEqual(selection.select(device("b")), .changed)
        XCTAssertEqual(selection.device?.id, "b")
        XCTAssertEqual(selection.select(nil), .changed)
        XCTAssertNil(selection.device)
    }
}
