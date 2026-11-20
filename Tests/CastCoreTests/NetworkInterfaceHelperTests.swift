import XCTest
import Foundation
@testable import CastCore

final class NetworkInterfaceHelperTests: XCTestCase {

    func testResolveIPv4AddressWithMockEn0() throws {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "lo0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true),
            NetworkInterface(name: "en0", address: "192.168.1.120", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        XCTAssertEqual(helper.getIPv4Address(for: "en0"), "192.168.1.120")

        let resolution = try helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertEqual(resolution.host, "192.168.1.120")
        XCTAssertEqual(resolution.interfaceName, "en0")
    }

    private func assertNoWiFi(
        _ interfaces: [NetworkInterface],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let helper = NetworkInterfaceHelper(provider: MockNetworkInterfaceProvider(interfaces: interfaces))
        XCTAssertThrowsError(try helper.resolveStreamIP(preferredInterface: "en0"), file: file, line: line) { error in
            XCTAssertEqual(error as? StreamURLError, .noWiFiIPv4Address, file: file, line: line)
        }
        XCTAssertThrowsError(try helper.resolveStreamURL(port: 8080), file: file, line: line) { error in
            XCTAssertEqual(error as? StreamURLError, .noWiFiIPv4Address, file: file, line: line)
        }
    }

    func testNoInterfacesThrowsNoWiFiError() {
        assertNoWiFi([])
    }

    func testOnlyLoopbackThrowsNoWiFiErrorNeverLocalhost() {
        assertNoWiFi([
            NetworkInterface(name: "lo0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true)
        ])
    }

    func testEn0OnlyIPv6ThrowsNoWiFiError() {
        assertNoWiFi([
            NetworkInterface(name: "en0", address: "fe80::1", isIPv4: false, isUp: true, isLoopback: false)
        ])
    }

    func testEn0DownThrowsNoWiFiError() {
        assertNoWiFi([
            NetworkInterface(name: "en0", address: "192.168.1.50", isIPv4: true, isUp: false, isLoopback: false)
        ])
    }

    func testEn0LoopbackAddressThrowsNoWiFiError() {
        assertNoWiFi([
            NetworkInterface(name: "en0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true)
        ])
    }

    func testNoWiFiErrorDescriptionIsUserFacing() {
        XCTAssertTrue(StreamURLError.noWiFiIPv4Address.localizedDescription.contains("Wi-Fi"))
    }
    func testFormatStreamURL() {
        let url1 = NetworkInterfaceHelper.formatStreamURL(host: "192.168.1.120", port: 8080, path: "view")
        XCTAssertEqual(url1, "http://192.168.1.120:8080/view")

        let url2 = NetworkInterfaceHelper.formatStreamURL(host: "localhost", port: 9000, path: "/view")
        XCTAssertEqual(url2, "http://localhost:9000/view")

        let url3 = NetworkInterfaceHelper.formatStreamURL(host: "10.0.0.1", port: 80, path: "stream.m3u8")
        XCTAssertEqual(url3, "http://10.0.0.1:80/stream.m3u8")

        let urlIPv6 = NetworkInterfaceHelper.formatStreamURL(host: "fe80::1", port: 8080, path: "view")
        XCTAssertEqual(urlIPv6, "http://[fe80::1]:8080/view")

        let urlIPv6Prebracketed = NetworkInterfaceHelper.formatStreamURL(host: "[::1]", port: 8080, path: "view")
        XCTAssertEqual(urlIPv6Prebracketed, "http://[::1]:8080/view")
    }

    func testQueryLoopbackExplicitlyReturnsAddress() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "lo0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        XCTAssertEqual(helper.getIPv4Address(for: "lo0"), "127.0.0.1")
    }

    func testFallsBackToAnyNonLoopbackInterfaceWhenEn0Missing() throws {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "eth0", address: "192.168.2.5", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let resolution = try helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertEqual(resolution.host, "192.168.2.5")
        XCTAssertEqual(resolution.interfaceName, "eth0")
    }

    func testResolveStreamURLConvenience() throws {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "10.0.0.42", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let (url, res) = try helper.resolveStreamURL(port: 8080)
        XCTAssertEqual(url, "http://10.0.0.42:8080/view")
        XCTAssertEqual(res.host, "10.0.0.42")
    }
    func testSystemNetworkInterfaceProviderLive() {
        let provider = SystemNetworkInterfaceProvider()
        let interfaces = provider.getInterfaces()
        // Should execute without crashing or memory issues, returning non-nil array
        XCTAssertNotNil(interfaces)
    }
}
