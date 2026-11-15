import XCTest
import Foundation
@testable import CastCore

final class NetworkInterfaceHelperTests: XCTestCase {

    func testResolveIPv4AddressWithMockEn0() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "lo0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true),
            NetworkInterface(name: "en0", address: "192.168.1.120", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let ip = helper.getIPv4Address(for: "en0")
        XCTAssertEqual(ip, "192.168.1.120")

        let resolution = helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertEqual(resolution.host, "192.168.1.120")
        XCTAssertFalse(resolution.isFallback)
        XCTAssertEqual(resolution.interfaceName, "en0")
        XCTAssertNil(resolution.warningMessage)
    }

    func testResolveIPv4AddressFallbackWhenEn0Missing() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "lo0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let ip = helper.getIPv4Address(for: "en0")
        XCTAssertNil(ip)

        let resolution = helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertEqual(resolution.host, "localhost")
        XCTAssertTrue(resolution.isFallback)
        XCTAssertNil(resolution.interfaceName)
        XCTAssertNotNil(resolution.warningMessage)
        XCTAssertTrue(resolution.warningMessage?.contains("Wi-Fi is disconnected") == true)
    }

    func testResolveIPv4AddressFallbackWhenEn0OnlyIPv6() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "fe80::1", isIPv4: false, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        XCTAssertNil(helper.getIPv4Address(for: "en0"))
        let resolution = helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertTrue(resolution.isFallback)
        XCTAssertEqual(resolution.host, "localhost")
    }

    func testResolveIPv4AddressFallbackWhenEn0Down() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "192.168.1.50", isIPv4: true, isUp: false, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        XCTAssertNil(helper.getIPv4Address(for: "en0"))
        let resolution = helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertTrue(resolution.isFallback)
        XCTAssertEqual(resolution.host, "localhost")
    }

    func testResolveIPv4AddressIgnoresLoopback() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: true)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        XCTAssertNil(helper.getIPv4Address(for: "en0"))
        let resolution = helper.resolveStreamIP(preferredInterface: "en0")
        XCTAssertTrue(resolution.isFallback)
    }

    func testCustomFallbackHost() {
        let mock = MockNetworkInterfaceProvider(interfaces: [])
        let helper = NetworkInterfaceHelper(provider: mock)

        let resolution = helper.resolveStreamIP(preferredInterface: "en0", fallbackHost: "127.0.0.1")
        XCTAssertEqual(resolution.host, "127.0.0.1")
        XCTAssertTrue(resolution.isFallback)
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

    func testFallbackToAnyNonLoopbackWhenEnabled() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "eth0", address: "192.168.2.5", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let disabled = helper.resolveStreamIP(preferredInterface: "en0", fallbackToAnyNonLoopback: false)
        XCTAssertTrue(disabled.isFallback)
        XCTAssertEqual(disabled.host, "localhost")

        let enabled = helper.resolveStreamIP(preferredInterface: "en0", fallbackToAnyNonLoopback: true)
        XCTAssertFalse(enabled.isFallback)
        XCTAssertEqual(enabled.host, "192.168.2.5")
        XCTAssertEqual(enabled.interfaceName, "eth0")
    }

    func testResolveStreamURLConvenience() {
        let mock = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "10.0.0.42", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mock)

        let (url, res) = helper.resolveStreamURL(port: 8080)
        XCTAssertEqual(url, "http://10.0.0.42:8080/view")
        XCTAssertFalse(res.isFallback)
        XCTAssertEqual(res.host, "10.0.0.42")
    }

    func testSystemNetworkInterfaceProviderLive() {
        let provider = SystemNetworkInterfaceProvider()
        let interfaces = provider.getInterfaces()
        // Should execute without crashing or memory issues, returning non-nil array
        XCTAssertNotNil(interfaces)
    }
}
