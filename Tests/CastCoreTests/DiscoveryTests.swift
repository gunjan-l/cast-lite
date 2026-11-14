import XCTest
import Foundation
@testable import CastCore

final class DiscoveryTests: XCTestCase {

    func testParseSSDPResponseRoku() {
        let rawSSDP = """
        HTTP/1.1 200 OK\r
        Cache-Control: max-age=3600\r
        ST: roku:ecp\r
        USN: uuid:roku:ecp:12345678\r
        Location: http://192.168.1.100:8060/\r
        Server: Roku/11.0.0 UPnP/1.0\r
        \r
        """

        let device = SSDPPacketParser.parse(packet: rawSSDP, senderIP: "192.168.1.100")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.id, "uuid:roku:ecp:12345678")
        XCTAssertEqual(device?.ipAddress, "192.168.1.100")
        XCTAssertEqual(device?.port, 8060)
        XCTAssertEqual(device?.type, .roku)
        XCTAssertEqual(device?.name, "Roku TV")
    }

    func testParseSSDPResponseDLNAMediaRenderer() {
        let rawSSDP = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: urn:schemas-upnp-org:device:MediaRenderer:1\r
        NTS: ssdp:alive\r
        USN: uuid:01234567-89ab-cdef-0123-456789abcdef::urn:schemas-upnp-org:device:MediaRenderer:1\r
        Location: http://192.168.1.105:7676/smp_2_\r
        Server: Samsung-Linux/4.1 UPnP/1.0 Samsung-WIFI-DIRECT/1.0\r
        \r
        """

        let device = SSDPPacketParser.parse(packet: rawSSDP, senderIP: "192.168.1.105")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.id, "uuid:01234567-89ab-cdef-0123-456789abcdef::urn:schemas-upnp-org:device:MediaRenderer:1")
        XCTAssertEqual(device?.ipAddress, "192.168.1.105")
        XCTAssertEqual(device?.port, 7676)
        XCTAssertEqual(device?.type, .dlna(brand: "Samsung"))
    }

    func testParseSSDPInvalidPacketIgnored() {
        let invalid = "HTTP/1.1 400 Bad Request\r\n\r\n"
        let device = SSDPPacketParser.parse(packet: invalid, senderIP: "192.168.1.200")
        XCTAssertNil(device)
    }

    func testDiscoveryEngineAggregationAndTimeout() async {
        let engine = DiscoveryEngine(offlineTimeout: 0.2) // 200ms timeout for test

        let device1 = DiscoveredDevice(
            id: "dev-1",
            name: "Living Room TV",
            type: .roku,
            ipAddress: "192.168.1.50",
            port: 8060,
            locationURL: URL(string: "http://192.168.1.50:8060/"),
            lastSeen: Date()
        )

        await engine.addOrUpdateDevice(device1)
        var devices = await engine.devices
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "dev-1")

        // Wait past offline timeout
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        await engine.pruneStaleDevices()
        devices = await engine.devices
        XCTAssertTrue(devices.isEmpty)
    }

    func testMDNSChromecastParsing() {
        let chromecast = MDNSParser.parseChromecast(name: "Chromecast-Ultra", ipAddress: "192.168.1.60", port: 8009)
        XCTAssertEqual(chromecast.type, .chromecast)
        XCTAssertEqual(chromecast.name, "Chromecast-Ultra")
        XCTAssertEqual(chromecast.port, 8009)
    }
}
