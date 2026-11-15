import XCTest
@testable import CastCore

final class CastTransportTests: XCTestCase {

    func testMockTransportConnectionLifecycle() async throws {
        let transport = MockCastTransport()
        XCTAssertFalse(transport.isConnected)

        try await transport.connect(host: "192.168.1.100", port: 8009)
        XCTAssertTrue(transport.isConnected)
        XCTAssertEqual(transport.connectedHost, "192.168.1.100")
        XCTAssertEqual(transport.connectedPort, 8009)

        await transport.close()
        XCTAssertFalse(transport.isConnected)
    }

    func testMockTransportSendWithoutConnectionThrows() async {
        let transport = MockCastTransport()
        let data = Data([0x01, 0x02])

        do {
            try await transport.send(data: data)
            XCTFail("Expected notConnected error")
        } catch let error as CastTransportError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReceiveStreamSetUpBeforeConnectReceivesData() async throws {
        let transport = MockCastTransport()
        // Caller sets up stream before connect
        let stream = transport.receiveStream()

        try await transport.connect(host: "10.0.0.5", port: 8009)

        let chunk = Data("early stream chunk".utf8)
        transport.simulateReceive(data: chunk)
        transport.finishReceiveStream()

        var received: [Data] = []
        for try await item in stream {
            received.append(item)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, chunk)
    }

    func testMockTransportSendRecordsPackets() async throws {
        let transport = MockCastTransport()
        try await transport.connect(host: "10.0.0.5", port: 8009)

        let packet1 = Data([0xAA, 0xBB])
        let packet2 = Data([0xCC, 0xDD, 0xEE])

        try await transport.send(data: packet1)
        try await transport.send(data: packet2)

        XCTAssertEqual(transport.sentPackets.count, 2)
        XCTAssertEqual(transport.sentPackets[0], packet1)
        XCTAssertEqual(transport.sentPackets[1], packet2)

        transport.clearSent()
        XCTAssertTrue(transport.sentPackets.isEmpty)
    }

    func testMockTransportReceiveStreamYieldsData() async throws {
        let transport = MockCastTransport()
        try await transport.connect(host: "10.0.0.5", port: 8009)

        let stream = transport.receiveStream()
        let chunk1 = Data("hello".utf8)
        let chunk2 = Data("world".utf8)

        transport.simulateReceive(data: chunk1)
        transport.simulateReceive(data: chunk2)
        transport.simulateDisconnect()

        var received: [Data] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], chunk1)
        XCTAssertEqual(received[1], chunk2)
    }

    func testMockTransportSimulateErrorTerminatesStream() async throws {
        let transport = MockCastTransport()
        try await transport.connect(host: "10.0.0.5", port: 8009)

        let stream = transport.receiveStream()
        transport.simulateError(CastTransportError.connectionFailed("Simulated network drop"))

        do {
            for try await _ in stream {
                // Should throw before completion
            }
            XCTFail("Expected stream to throw error")
        } catch let error as CastTransportError {
            if case .connectionFailed(let message) = error {
                XCTAssertEqual(message, "Simulated network drop")
            } else {
                XCTFail("Unexpected error case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMockTransportIntegratedFramedCastMessageExchange() async throws {
        let transport = MockCastTransport()
        try await transport.connect(host: "192.168.1.50", port: 8009)

        // Incoming message from Chromecast: RECEIVER_STATUS
        let incomingMessage = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "receiver-0",
            destinationId: "sender-0",
            namespace: "urn:x-cast:com.google.cast.receiver",
            payloadType: .string,
            payloadUtf8: "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1}"
        )
        let framedIncoming = try CastPacketFramer.frame(message: incomingMessage)

        // Simulate receiving in 2 fragments
        let splitIndex = framedIncoming.count / 2
        let frag1 = framedIncoming.subdata(in: 0..<splitIndex)
        let frag2 = framedIncoming.subdata(in: splitIndex..<framedIncoming.count)

        var framer = CastPacketFramer()
        let stream = transport.receiveStream()

        transport.simulateReceive(data: frag1)
        transport.simulateReceive(data: frag2)
        transport.finishReceiveStream()

        var decodedMessages: [CastMessage] = []
        for try await chunk in stream {
            let packets = try framer.append(chunk)
            for packet in packets {
                let msg = try CastMessageCodec.decode(packet)
                decodedMessages.append(msg)
            }
        }

        XCTAssertEqual(decodedMessages.count, 1)
        XCTAssertEqual(decodedMessages.first?.payloadUtf8, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1}")

        // Client responds with a framed message
        let outgoingMessage = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.tp.heartbeat",
            payloadType: .string,
            payloadUtf8: "{\"type\":\"PING\"}"
        )
        let framedOutgoing = try CastPacketFramer.frame(message: outgoingMessage)
        try await transport.send(data: framedOutgoing)

        XCTAssertEqual(transport.sentPackets.count, 1)
        let sentFramed = transport.sentPackets[0]
        var verifyFramer = CastPacketFramer()
        let verifiedPackets = try verifyFramer.append(sentFramed)
        XCTAssertEqual(verifiedPackets.count, 1)
        let verifiedMsg = try CastMessageCodec.decode(verifiedPackets[0])
        XCTAssertEqual(verifiedMsg.namespace, "urn:x-cast:com.google.cast.tp.heartbeat")
        XCTAssertEqual(verifiedMsg.payloadUtf8, "{\"type\":\"PING\"}")
    }

    func testMockTransportConnectionFailureSimulation() async {
        let transport = MockCastTransport()
        transport.shouldFailConnection = CastTransportError.connectionFailed("Host unreachable")

        do {
            try await transport.connect(host: "10.0.0.99", port: 8009)
            XCTFail("Expected connect to throw")
        } catch let error as CastTransportError {
            if case .connectionFailed(let reason) = error {
                XCTAssertEqual(reason, "Host unreachable")
            } else {
                XCTFail("Unexpected error case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(transport.isConnected)
    }

    func testMockTransportOnSendHook() async throws {
        final class HookState: @unchecked Sendable {
            var hookTriggered = false
            var capturedData = Data()
        }
        let state = HookState()

        let transport = MockCastTransport()
        try await transport.connect(host: "10.0.0.1", port: 8009)

        transport.onSend = { data in
            state.hookTriggered = true
            state.capturedData = data
        }

        let sentData = Data([0xDE, 0xAD])
        try await transport.send(data: sentData)

        XCTAssertTrue(state.hookTriggered)
        XCTAssertEqual(state.capturedData, sentData)
    }

    func testMockTransportCloseTerminatesStream() async throws {
        let transport = MockCastTransport()
        try await transport.connect(host: "10.0.0.1", port: 8009)

        let stream = transport.receiveStream()
        await transport.close()

        var received: [Data] = []
        for try await chunk in stream {
            received.append(chunk)
        }
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(transport.isConnected)
    }
}
