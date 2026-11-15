import XCTest
@testable import CastCore

final class CastV2ClientTests: XCTestCase {

    // MARK: - Helpers

    private func decodeSentMessages(from transport: MockCastTransport) throws -> [CastMessage] {
        var framer = CastPacketFramer()
        var messages: [CastMessage] = []
        for packet in transport.sentPackets {
            let unmarshalled = try framer.append(packet)
            for payload in unmarshalled {
                let msg = try CastMessageCodec.decode(payload)
                messages.append(msg)
            }
        }
        return messages
    }

    private func makeReceiverStatusJSON(
        requestId: Int,
        appId: String = "CC1AD845",
        sessionId: String = "session-test-123",
        transportId: String = "transport-test-456"
    ) -> String {
        """
        {
            "type": "RECEIVER_STATUS",
            "requestId": \(requestId),
            "status": {
                "applications": [
                    {
                        "appId": "\(appId)",
                        "displayName": "Default Media Receiver",
                        "sessionId": "\(sessionId)",
                        "statusText": "Ready",
                        "transportId": "\(transportId)"
                    }
                ],
                "volume": {
                    "level": 1.0,
                    "muted": false
                }
            }
        }
        """
    }

    // MARK: - Connection & Handshake Tests

    func testConnectSendsInitialConnectFrameToReceiver0() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 5.0
        )

        let initialConnected = await client.isConnected
        XCTAssertFalse(initialConnected)
        try await client.connect(host: "192.168.1.150", port: 8009)
        let isConnectedAfterConnect = await client.isConnected
        XCTAssertTrue(isConnectedAfterConnect)

        let sent = try decodeSentMessages(from: transport)
        XCTAssertFalse(sent.isEmpty)

        // The first message must be CONNECT to receiver-0
        let connectMsg = sent[0]
        XCTAssertEqual(connectMsg.namespace, "urn:x-cast:com.google.cast.tp.connection")
        XCTAssertEqual(connectMsg.sourceId, "sender-0")
        XCTAssertEqual(connectMsg.destinationId, "receiver-0")
        XCTAssertEqual(connectMsg.payloadType, .string)

        guard let payloadUtf8 = connectMsg.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected valid JSON payload in CONNECT message")
            return
        }
        XCTAssertEqual(json["type"] as? String, "CONNECT")

        await client.disconnect()
    }

    func testConnectWhenAlreadyConnectedThrows() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 5.0
        )

        try await client.connect(host: "192.168.1.150", port: 8009)
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected)

        do {
            try await client.connect(host: "192.168.1.150", port: 8009)
            XCTFail("Expected alreadyConnected error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .alreadyConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await client.disconnect()
    }

    // MARK: - Heartbeat Tests

    func testHeartbeatPeriodicPingGeneration() async throws {
        let transport = MockCastTransport()
        // Fast interval: 30ms
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 0.03,
            requestTimeout: 5.0
        )

        try await client.connect(host: "192.168.1.150", port: 8009)

        // Wait ~100ms so at least 2 PINGs fire
        try await Task.sleep(nanoseconds: 100_000_000)

        let sent = try decodeSentMessages(from: transport)
        let pingMessages = sent.filter { msg in
            msg.namespace == "urn:x-cast:com.google.cast.tp.heartbeat" &&
            (msg.payloadUtf8?.contains("\"PING\"") == true)
        }

        XCTAssertGreaterThanOrEqual(pingMessages.count, 2)
        XCTAssertEqual(pingMessages.first?.destinationId, "receiver-0")
        XCTAssertEqual(pingMessages.first?.sourceId, "sender-0")

        await client.disconnect()
    }

    func testHeartbeatIncomingPingRespondsWithPong() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 5.0
        )

        try await client.connect(host: "192.168.1.150", port: 8009)
        transport.clearSent()

        // Receiver sends a PING
        let incomingPing = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "receiver-0",
            destinationId: "sender-0",
            namespace: "urn:x-cast:com.google.cast.tp.heartbeat",
            payloadType: .string,
            payloadUtf8: "{\"type\":\"PING\"}"
        )
        let framedPing = try CastPacketFramer.frame(message: incomingPing)
        transport.simulateReceive(data: framedPing)

        // Give the actor receive loop a brief moment to process
        try await Task.sleep(nanoseconds: 30_000_000)

        let sent = try decodeSentMessages(from: transport)
        let pongMessages = sent.filter { msg in
            msg.namespace == "urn:x-cast:com.google.cast.tp.heartbeat" &&
            (msg.payloadUtf8?.contains("\"PONG\"") == true)
        }

        XCTAssertFalse(pongMessages.isEmpty)
        let pong = pongMessages[0]
        XCTAssertEqual(pong.sourceId, "sender-0")
        XCTAssertEqual(pong.destinationId, "receiver-0")

        await client.disconnect()
    }

    // MARK: - Receiver Launch & Request Correlation Tests

    func testLaunchReceiverSuccessAndAppChannelConnect() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        // Intercept sent messages: when LAUNCH is sent, simulate RECEIVER_STATUS response
        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet) else { return }

            if msg.namespace == "urn:x-cast:com.google.cast.receiver",
               let payload = msg.payloadUtf8,
               payload.contains("\"LAUNCH\"") {
                // Extract requestId from sent LAUNCH message
                guard let d = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let reqId = json["requestId"] as? Int else { return }

                let statusJSON = """
                {
                    "type": "RECEIVER_STATUS",
                    "requestId": \(reqId),
                    "status": {
                        "applications": [
                            {
                                "appId": "CC1AD845",
                                "displayName": "Default Media Receiver",
                                "sessionId": "sess-alpha-777",
                                "statusText": "Ready",
                                "transportId": "web-transport-99"
                            }
                        ]
                    }
                }
                """
                let respMsg = CastMessage(
                    protocolVersion: .castv2_1_0,
                    sourceId: "receiver-0",
                    destinationId: "sender-0",
                    namespace: "urn:x-cast:com.google.cast.receiver",
                    payloadType: .string,
                    payloadUtf8: statusJSON
                )
                let framedResp = try! CastPacketFramer.frame(message: respMsg)
                transport?.simulateReceive(data: framedResp)
            }
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        let result = try await client.launchReceiver(appId: "CC1AD845")
        XCTAssertEqual(result.sessionId, "sess-alpha-777")
        XCTAssertEqual(result.transportId, "web-transport-99")
        let sessionId = await client.activeSessionId
        let transportId = await client.activeTransportId
        XCTAssertEqual(sessionId, "sess-alpha-777")
        XCTAssertEqual(transportId, "web-transport-99")

        let sent = try decodeSentMessages(from: transport)

        // Verify LAUNCH message
        let launchMsgs = sent.filter { $0.namespace == "urn:x-cast:com.google.cast.receiver" }
        XCTAssertEqual(launchMsgs.count, 1)
        XCTAssertEqual(launchMsgs[0].destinationId, "receiver-0")
        XCTAssertEqual(launchMsgs[0].sourceId, "sender-0")

        // Verify CONNECT message sent to transportId ("web-transport-99")
        let appConnectMsgs = sent.filter {
            $0.namespace == "urn:x-cast:com.google.cast.tp.connection" &&
            $0.destinationId == "web-transport-99"
        }
        XCTAssertEqual(appConnectMsgs.count, 1)
        XCTAssertEqual(appConnectMsgs[0].payloadUtf8?.contains("\"CONNECT\""), true)

        await client.disconnect()
    }

    func testLaunchReceiverAppNotFoundThrows() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet) else { return }

            if msg.namespace == "urn:x-cast:com.google.cast.receiver",
               let payload = msg.payloadUtf8,
               let d = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let reqId = json["requestId"] as? Int {

                // Return a different app
                let statusJSON = """
                {
                    "type": "RECEIVER_STATUS",
                    "requestId": \(reqId),
                    "status": {
                        "applications": [
                            {
                                "appId": "OTHER_APP",
                                "displayName": "Other App",
                                "sessionId": "sess-other",
                                "transportId": "transport-other"
                            }
                        ]
                    }
                }
                """
                let respMsg = CastMessage(
                    protocolVersion: .castv2_1_0,
                    sourceId: "receiver-0",
                    destinationId: "sender-0",
                    namespace: "urn:x-cast:com.google.cast.receiver",
                    payloadType: .string,
                    payloadUtf8: statusJSON
                )
                let framedResp = try! CastPacketFramer.frame(message: respMsg)
                transport?.simulateReceive(data: framedResp)
            }
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        do {
            _ = try await client.launchReceiver(appId: "CC1AD845")
            XCTFail("Expected applicationNotFound error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .applicationNotFound("CC1AD845"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await client.disconnect()
    }

    func testRequestTimeoutWhenReceiverDoesNotReply() async throws {
        let transport = MockCastTransport()
        // Fast timeout: 0.05s
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 0.05
        )

        try await client.connect(host: "192.168.1.150", port: 8009)

        do {
            _ = try await client.launchReceiver(appId: "CC1AD845")
            XCTFail("Expected timeout error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .timeout(1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await client.disconnect()
    }

    func testRequestIdIncrementsMonotonically() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet),
                  msg.namespace == "urn:x-cast:com.google.cast.receiver",
                  let payload = msg.payloadUtf8,
                  let d = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reqId = json["requestId"] as? Int else { return }

            let statusJSON = """
            {
                "type": "RECEIVER_STATUS",
                "requestId": \(reqId),
                "status": {
                    "applications": [
                        {
                            "appId": "CC1AD845",
                            "sessionId": "s\(reqId)",
                            "transportId": "t\(reqId)"
                        }
                    ]
                }
            }
            """
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: "receiver-0",
                destinationId: "sender-0",
                namespace: "urn:x-cast:com.google.cast.receiver",
                payloadType: .string,
                payloadUtf8: statusJSON
            )
            let framedResp = try! CastPacketFramer.frame(message: respMsg)
            transport?.simulateReceive(data: framedResp)
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        let res1 = try await client.launchReceiver(appId: "CC1AD845")
        XCTAssertEqual(res1.sessionId, "s1")
        XCTAssertEqual(res1.transportId, "t1")

        let res2 = try await client.launchReceiver(appId: "CC1AD845")
        XCTAssertEqual(res2.sessionId, "s2")
        XCTAssertEqual(res2.transportId, "t2")

        let sent = try decodeSentMessages(from: transport)
        let launchMsgs = sent.filter { $0.namespace == "urn:x-cast:com.google.cast.receiver" }
        XCTAssertEqual(launchMsgs.count, 2)

        // Parse payloads
        let p1 = try JSONSerialization.jsonObject(with: launchMsgs[0].payloadUtf8!.data(using: .utf8)!) as! [String: Any]
        let p2 = try JSONSerialization.jsonObject(with: launchMsgs[1].payloadUtf8!.data(using: .utf8)!) as! [String: Any]

        XCTAssertEqual(p1["requestId"] as? Int, 1)
        XCTAssertEqual(p2["requestId"] as? Int, 2)

        await client.disconnect()
    }

    // MARK: - Teardown & Stream Termination Tests

    func testTeardownSendsCloseMessagesAndStopsHeartbeat() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 0.03,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet),
                  msg.namespace == "urn:x-cast:com.google.cast.receiver",
                  let payload = msg.payloadUtf8,
                  let d = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reqId = json["requestId"] as? Int else { return }

            let statusJSON = """
            {
                "type": "RECEIVER_STATUS",
                "requestId": \(reqId),
                "status": {
                    "applications": [
                        {
                            "appId": "CC1AD845",
                            "sessionId": "s-close",
                            "transportId": "web-close-99"
                        }
                    ]
                }
            }
            """
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: "receiver-0",
                destinationId: "sender-0",
                namespace: "urn:x-cast:com.google.cast.receiver",
                payloadType: .string,
                payloadUtf8: statusJSON
            )
            let framedResp = try! CastPacketFramer.frame(message: respMsg)
            transport?.simulateReceive(data: framedResp)
        }

        try await client.connect(host: "192.168.1.150", port: 8009)
        _ = try await client.launchReceiver(appId: "CC1AD845")

        // Now disconnect
        await client.disconnect()

        let isConnected = await client.isConnected
        let sessionId = await client.activeSessionId
        let transportId = await client.activeTransportId
        XCTAssertFalse(isConnected)
        XCTAssertFalse(transport.isConnected)
        XCTAssertNil(sessionId)
        XCTAssertNil(transportId)

        let sent = try decodeSentMessages(from: transport)

        // Verify CLOSE messages sent
        let closeMsgs = sent.filter {
            $0.namespace == "urn:x-cast:com.google.cast.tp.connection" &&
            $0.payloadUtf8?.contains("\"CLOSE\"") == true
        }

        // Must have sent CLOSE to active transportId ("web-close-99") and receiver-0
        let closeDestinations = closeMsgs.map { $0.destinationId }
        XCTAssertTrue(closeDestinations.contains("web-close-99"))
        XCTAssertTrue(closeDestinations.contains("receiver-0"))

        // Heartbeat must be stopped: record count of sent packets, sleep, assert no new packets
        let countAfterDisconnect = transport.sentPackets.count
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(transport.sentPackets.count, countAfterDisconnect)
    }

    func testDisconnectCancelsPendingRequests() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 10.0 // Long timeout
        )

        try await client.connect(host: "192.168.1.150", port: 8009)

        // Launch request in background task without simulating reply
        let launchTask = Task {
            try await client.launchReceiver(appId: "CC1AD845")
        }

        // Give task a moment to register request
        try await Task.sleep(nanoseconds: 20_000_000)

        // Disconnect immediately
        await client.disconnect()

        do {
            _ = try await launchTask.value
            XCTFail("Expected disconnected error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIncomingStreamFragmentationHandledCorrectly() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet),
                  msg.namespace == "urn:x-cast:com.google.cast.receiver",
                  let payload = msg.payloadUtf8,
                  let d = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reqId = json["requestId"] as? Int else { return }

            let statusJSON = """
            {
                "type": "RECEIVER_STATUS",
                "requestId": \(reqId),
                "status": {
                    "applications": [
                        {
                            "appId": "CC1AD845",
                            "sessionId": "sess-fragmented",
                            "transportId": "transport-frag-1"
                        }
                    ]
                }
            }
            """
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: "receiver-0",
                destinationId: "sender-0",
                namespace: "urn:x-cast:com.google.cast.receiver",
                payloadType: .string,
                payloadUtf8: statusJSON
            )
            let framedResp = try! CastPacketFramer.frame(message: respMsg)

            // Simulate arriving in 3 byte slices
            let sliceSize = framedResp.count / 3
            let s1 = framedResp.subdata(in: 0..<sliceSize)
            let s2 = framedResp.subdata(in: sliceSize..<(sliceSize * 2))
            let s3 = framedResp.subdata(in: (sliceSize * 2)..<framedResp.count)

            transport?.simulateReceive(data: s1)
            transport?.simulateReceive(data: s2)
            transport?.simulateReceive(data: s3)
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        let result = try await client.launchReceiver(appId: "CC1AD845")
        XCTAssertEqual(result.sessionId, "sess-fragmented")
        XCTAssertEqual(result.transportId, "transport-frag-1")

        await client.disconnect()
    }

    // MARK: - Additional Edge Cases

    func testLaunchReceiverWhenNotConnectedThrowsNotConnected() async {
        let transport = MockCastTransport()
        let client = CastV2Client(transport: transport)

        do {
            _ = try await client.launchReceiver(appId: "CC1AD845")
            XCTFail("Expected notConnected error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSendCastMessageWhenNotConnectedThrowsNotConnected() async {
        let transport = MockCastTransport()
        let client = CastV2Client(transport: transport)

        let msg = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.tp.heartbeat",
            payloadType: .string,
            payloadUtf8: "{\"type\":\"PING\"}"
        )

        do {
            try await client.send(message: msg)
            XCTFail("Expected notConnected error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLaunchReceiverWhenReceiverReturnsLaunchErrorThrows() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet),
                  msg.namespace == "urn:x-cast:com.google.cast.receiver",
                  let payload = msg.payloadUtf8,
                  let d = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reqId = json["requestId"] as? Int else { return }

            let errorJSON = """
            {
                "type": "LAUNCH_ERROR",
                "requestId": \(reqId),
                "reason": "USER_PENDING"
            }
            """
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: "receiver-0",
                destinationId: "sender-0",
                namespace: "urn:x-cast:com.google.cast.receiver",
                payloadType: .string,
                payloadUtf8: errorJSON
            )
            let framedResp = try! CastPacketFramer.frame(message: respMsg)
            transport?.simulateReceive(data: framedResp)
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        do {
            _ = try await client.launchReceiver(appId: "CC1AD845")
            XCTFail("Expected launchFailed error")
        } catch let error as CastV2Error {
            XCTAssertEqual(error, .launchFailed("USER_PENDING"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await client.disconnect()
    }

    func testLaunchReceiverWhenResponseHasMalformedStatusThrowsInvalidResponse() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        transport.onSend = { [weak transport] data in
            var framer = CastPacketFramer()
            guard let packets = try? framer.append(data),
                  let packet = packets.first,
                  let msg = try? CastMessageCodec.decode(packet),
                  msg.namespace == "urn:x-cast:com.google.cast.receiver",
                  let payload = msg.payloadUtf8,
                  let d = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reqId = json["requestId"] as? Int else { return }

            // Response missing status.applications
            let malformedJSON = """
            {
                "type": "RECEIVER_STATUS",
                "requestId": \(reqId)
            }
            """
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: "receiver-0",
                destinationId: "sender-0",
                namespace: "urn:x-cast:com.google.cast.receiver",
                payloadType: .string,
                payloadUtf8: malformedJSON
            )
            let framedResp = try! CastPacketFramer.frame(message: respMsg)
            transport?.simulateReceive(data: framedResp)
        }

        try await client.connect(host: "192.168.1.150", port: 8009)

        do {
            _ = try await client.launchReceiver(appId: "CC1AD845")
            XCTFail("Expected invalidResponse error")
        } catch let error as CastV2Error {
            if case .invalidResponse = error {
                // Expected
            } else {
                XCTFail("Unexpected CastV2Error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await client.disconnect()
    }

    func testDisconnectWhenAlreadyDisconnectedIsNoOp() async {
        let transport = MockCastTransport()
        let client = CastV2Client(transport: transport)

        let initialConnected = await client.isConnected
        XCTAssertFalse(initialConnected)

        await client.disconnect()

        let stillConnected = await client.isConnected
        XCTAssertFalse(stillConnected)
    }

    func testTransportStreamErrorTriggersDisconnect() async throws {
        let transport = MockCastTransport()
        let client = CastV2Client(
            transport: transport,
            clientSourceId: "sender-0",
            heartbeatInterval: 60.0,
            requestTimeout: 2.0
        )

        try await client.connect(host: "192.168.1.150", port: 8009)
        let isConnectedBefore = await client.isConnected
        XCTAssertTrue(isConnectedBefore)

        transport.simulateError(CastTransportError.connectionFailed("Socket drop"))

        // Give receive task time to process error
        try await Task.sleep(nanoseconds: 30_000_000)

        let isConnectedAfter = await client.isConnected
        XCTAssertFalse(isConnectedAfter)
    }
}
