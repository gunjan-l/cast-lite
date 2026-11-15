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

    func testMockSSDPPacketIngestionAndRegistration() async {
        let mockTransport = MockSSDPTransport()
        let rawRoku = """
        HTTP/1.1 200 OK\r
        Cache-Control: max-age=3600\r
        ST: roku:ecp\r
        USN: uuid:roku:ecp:test-roku-1\r
        Location: http://192.168.1.111:8060/\r
        Server: Roku/11.0.0 UPnP/1.0\r
        \r
        """
        mockTransport.enqueuePacket(text: rawRoku, senderIP: "192.168.1.111")

        let engine = DiscoveryEngine(transport: mockTransport)
        await engine.startDiscovery()

        // Wait brief moment for background listener loop to process packet
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let current = await engine.devices
            if !current.isEmpty { break }
        }

        let devices = await engine.devices
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "uuid:roku:ecp:test-roku-1")
        XCTAssertEqual(devices.first?.ipAddress, "192.168.1.111")
        XCTAssertEqual(devices.first?.name, "Roku TV")

        await engine.stopDiscovery()
        XCTAssertTrue(mockTransport.isClosed)
    }

    func testMockSSDPRealTimeNotifications() async {
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(transport: mockTransport)

        let updateReceived = expectation(description: "Real-time device update received")
        await engine.setOnDevicesChanged { devices in
            if devices.contains(where: { $0.id == "uuid:samsung-tv-notify" }) {
                updateReceived.fulfill()
            }
        }

        await engine.startDiscovery()

        let rawNotify = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: urn:schemas-upnp-org:device:MediaRenderer:1\r
        NTS: ssdp:alive\r
        USN: uuid:samsung-tv-notify\r
        Location: http://192.168.1.120:7676/smp_\r
        Server: Samsung-Linux/4.1 UPnP/1.0\r
        \r
        """
        mockTransport.enqueuePacket(text: rawNotify, senderIP: "192.168.1.120")

        await fulfillment(of: [updateReceived], timeout: 2.0)

        let devices = await engine.devices
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Samsung TV")

        await engine.stopDiscovery()
    }

    func testMockSSDPGracefulShutdownAndErrorHandling() async {
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(transport: mockTransport)

        await engine.startDiscovery()
        var searching = await engine.isSearching
        XCTAssertTrue(searching)

        // Inject simulated transport failure
        mockTransport.shouldThrowOnReceive = true

        // Let the listener loop handle error
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Stop discovery gracefully
        await engine.stopDiscovery()
        searching = await engine.isSearching
        XCTAssertFalse(searching)
        XCTAssertTrue(mockTransport.isClosed)
    }

    func testSendSSDPMSearchUsesTransport() async {
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(transport: mockTransport)

        await engine.sendSSDPMSearch()

        XCTAssertEqual(mockTransport.sentPackets.count, 1)
        let sent = mockTransport.sentPackets.first
        XCTAssertEqual(sent?.host, "239.255.255.250")
        XCTAssertEqual(sent?.port, 1900)
        let sentText = String(data: sent?.data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(sentText.contains("M-SEARCH * HTTP/1.1"))
    }

    func testDefaultSSDPTransportLoopbackSendAndReceive() throws {
        let receiver = DefaultSSDPTransport()
        let port = try receiver.bind(port: 0)
        XCTAssertGreaterThan(port, 0)

        let sender = DefaultSSDPTransport()
        let testPayload = "M-SEARCH * HTTP/1.1\r\n\r\n"
        try sender.sendMulticast(data: Data(testPayload.utf8), toHost: "127.0.0.1", port: port)

        var receivedData: (data: Data, senderIP: String, senderPort: UInt16)?
        for _ in 0..<10 {
            if let result = try receiver.receive() {
                receivedData = result
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertNotNil(receivedData)
        let receivedStr = String(data: receivedData?.data ?? Data(), encoding: .utf8)
        XCTAssertEqual(receivedStr, testPayload)

        receiver.close()
        sender.close()
    }

    func testGenericDLNASSDPPacketYieldsSmartTVNotSmartTVTV() {
        let rawSSDP = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: urn:schemas-upnp-org:device:MediaRenderer:1\r
        NTS: ssdp:alive\r
        USN: uuid:generic-tv-123::urn:schemas-upnp-org:device:MediaRenderer:1\r
        Location: http://192.168.1.120:8080/description.xml\r
        Server: Linux/4.1 UPnP/1.0\r
        \r
        """

        let device = SSDPPacketParser.parse(packet: rawSSDP, senderIP: "192.168.1.120")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.name, "Smart TV")
        XCTAssertEqual(device?.controlURL?.absoluteString, "http://192.168.1.120:8080/upnp/control/AVTransport1")
    }

    func testDiscoveryEnginePreservesExistingDeviceNameOnGenericUpdate() async {
        let engine = DiscoveryEngine()
        let customDevice = DiscoveredDevice(
            id: "uuid:living-room-tv",
            name: "Living Room OLED",
            type: .dlna(brand: "Smart TV"),
            ipAddress: "192.168.1.120",
            port: 8080
        )
        await engine.addOrUpdateDevice(customDevice)

        let genericUpdate = DiscoveredDevice(
            id: "uuid:living-room-tv",
            name: "Smart TV",
            type: .dlna(brand: "Smart TV"),
            ipAddress: "192.168.1.120",
            port: 8080
        )
        await engine.addOrUpdateDevice(genericUpdate)

        let devices = await engine.devices
        XCTAssertEqual(devices.first?.name, "Living Room OLED")
    }

    func testSendAllSSDPMSearchesSendsMultipleTargets() async {
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(transport: mockTransport)

        await engine.sendAllSSDPMSearches()

        XCTAssertEqual(mockTransport.sentPackets.count, 4)
        let payloads = mockTransport.sentPackets.compactMap { String(data: $0.data, encoding: .utf8) }

        XCTAssertTrue(payloads.contains { $0.contains("ST: ssdp:all") })
        XCTAssertTrue(payloads.contains { $0.contains("ST: upnp:rootdevice") })
        XCTAssertTrue(payloads.contains { $0.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1") })
        XCTAssertTrue(payloads.contains { $0.contains("ST: roku:ecp") })
    }

    func testPeriodicProbeCadence() async {
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(probeInterval: 0.05, transport: mockTransport)

        await engine.startDiscovery()

        // Wait for initial burst + at least 1-2 periodic probe cycles
        try? await Task.sleep(nanoseconds: 120_000_000)

        await engine.stopDiscovery()

        // Initial burst = 4, after cycles should be at least 8
        XCTAssertGreaterThanOrEqual(mockTransport.sentPackets.count, 8)
    }

    func testDefaultSSDPTransportUsesNetworkHelperInterface() throws {
        let mockProvider = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "127.0.0.1", isIPv4: true, isUp: true, isLoopback: false)
        ])
        let helper = NetworkInterfaceHelper(provider: mockProvider)
        let transport = DefaultSSDPTransport(networkHelper: helper)

        let port = try transport.bind(port: 0)
        XCTAssertGreaterThan(port, 0)
        transport.close()
    }

    func testBonjourChromecastDiscoveryIntegration() async {
        let mockBonjour = MockBonjourDiscoveryProvider()
        let mockTransport = MockSSDPTransport()
        let engine = DiscoveryEngine(transport: mockTransport, bonjourProvider: mockBonjour)

        let expectation = expectation(description: "Chromecast device discovered via Bonjour")
        await engine.setOnDevicesChanged { devices in
            if devices.contains(where: { $0.id == "chromecast-192.168.1.55:8009" }) {
                expectation.fulfill()
            }
        }

        await engine.startDiscovery()
        XCTAssertTrue(mockBonjour.isBrowsing)

        let chromecast = MDNSParser.parseChromecast(name: "Basement TV", ipAddress: "192.168.1.55", port: 8009)
        mockBonjour.simulateDeviceFound(chromecast)

        await fulfillment(of: [expectation], timeout: 2.0)

        let devices = await engine.devices
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Basement TV")
        XCTAssertEqual(devices.first?.type, .chromecast)

        await engine.stopDiscovery()
        XCTAssertFalse(mockBonjour.isBrowsing)
    }

    func testMDNSTXTRecordParsing() {
        // Construct raw DNS-SD TXT payload: <len>fn=Living Room<len>md=Chromecast Ultra
        var rawData = Data()
        let item1 = "fn=Living Room"
        rawData.append(UInt8(item1.utf8.count))
        rawData.append(Data(item1.utf8))

        let item2 = "md=Chromecast Ultra"
        rawData.append(UInt8(item2.utf8.count))
        rawData.append(Data(item2.utf8))

        let parsed = MDNSParser.parseTXTRecord(data: rawData)
        XCTAssertEqual(parsed["fn"], "Living Room")
        XCTAssertEqual(parsed["md"], "Chromecast Ultra")
    }
}
