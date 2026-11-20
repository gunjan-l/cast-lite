import XCTest
import Foundation
@testable import CastCore

final class CastSessionCoordinatorTests: XCTestCase {

    private func makeChromecastDevice(ip: String = "192.168.1.50") -> DiscoveredDevice {
        DiscoveredDevice(
            id: "chromecast-\(ip)",
            name: "Living Room TV",
            type: .chromecast,
            ipAddress: ip,
            port: 8009
        )
    }

    private func makeRokuDevice(ip: String = "192.168.1.60") -> DiscoveredDevice {
        DiscoveredDevice(
            id: "roku-\(ip)",
            name: "Roku Ultra",
            type: .roku,
            ipAddress: ip,
            port: 8060
        )
    }

    private func makeDLNADevice(ip: String = "192.168.1.70") -> DiscoveredDevice {
        DiscoveredDevice(
            id: "dlna-\(ip)",
            name: "Smart DLNA TV",
            type: .dlna(brand: "Samsung"),
            ipAddress: ip,
            port: 1400
        )
    }

    // MARK: - Test Harness Helper

    final class MockChromecastDevice: @unchecked Sendable {
        let transport: MockCastTransport
        enum LoadBehavior {
            case playing, buffering, silent, idleError
            case loadFailed(String)
            case invalidRequest(String)
        }
        var mediaSessionIdToReturn: Int = 1234
        var loadBehavior: LoadBehavior = .playing
        private let lock = NSLock()
        private var _sentMessages: [CastMessage] = []
        private var framer = CastPacketFramer()

        var sentMessages: [CastMessage] {
            lock.lock()
            defer { lock.unlock() }
            return _sentMessages
        }

        init(transport: MockCastTransport = MockCastTransport()) {
            self.transport = transport
            setupResponder()
        }

        private func setupResponder() {
            transport.onSend = { [weak self, weak transport] data in
                guard let self = self, let transport = transport else { return }
                guard let packets = try? self.framer.append(data) else { return }
                for packet in packets {
                    guard let msg = try? CastMessageCodec.decode(packet) else { continue }
                    self.lock.lock()
                    self._sentMessages.append(msg)
                    self.lock.unlock()
                    self.handleMessage(msg, transport: transport)
                }
            }
        }

        private func handleMessage(_ msg: CastMessage, transport: MockCastTransport) {
            guard let payloadUtf8 = msg.payloadUtf8,
                  let data = payloadUtf8.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reqId = json["requestId"] as? Int,
                  let type = json["type"] as? String else {
                return
            }

            if msg.namespace == CastNamespaces.receiver && type == "LAUNCH" {
                let statusJSON = """
                {
                    "type": "RECEIVER_STATUS",
                    "requestId": \(reqId),
                    "status": {
                        "applications": [
                            {
                                "appId": "\(CastConstants.defaultAppId)",
                                "displayName": "Default Media Receiver",
                                "sessionId": "mock-sess-001",
                                "statusText": "Ready",
                                "transportId": "mock-transport-001"
                            }
                        ]
                    }
                }
                """
                let respMsg = CastMessage(
                    protocolVersion: .castv2_1_0,
                    sourceId: "receiver-0",
                    destinationId: msg.sourceId,
                    namespace: CastNamespaces.receiver,
                    payloadType: .string,
                    payloadUtf8: statusJSON
                )
                if let framed = try? CastPacketFramer.frame(message: respMsg) {
                    transport.simulateReceive(data: framed)
                }
            } else if msg.namespace == CastNamespaces.media && type == "LOAD" {
                let mediaStatusJSON: String
                switch self.loadBehavior {
                case .silent:
                    return
                case .playing:
                    mediaStatusJSON = mediaStatus(reqId: reqId, state: "PLAYING")
                case .buffering:
                    mediaStatusJSON = mediaStatus(reqId: reqId, state: "BUFFERING")
                case .loadFailed(let reason):
                    mediaStatusJSON = "{\"type\":\"LOAD_FAILED\",\"requestId\":\(reqId),\"reason\":\"\(reason)\"}"
                case .invalidRequest(let reason):
                    mediaStatusJSON = "{\"type\":\"INVALID_REQUEST\",\"requestId\":\(reqId),\"reason\":\"\(reason)\"}"
                case .idleError:
                    mediaStatusJSON = mediaStatus(reqId: reqId, state: "IDLE", idleReason: "ERROR")
                }
                reply(namespace: CastNamespaces.media, from: msg.destinationId, to: msg.sourceId, json: mediaStatusJSON, transport: transport)
            }
        }

        private func mediaStatus(reqId: Int, state: String, idleReason: String? = nil) -> String {
            let idle = idleReason.map { ",\"idleReason\":\"\($0)\"" } ?? ""
            return "{\"type\":\"MEDIA_STATUS\",\"requestId\":\(reqId),\"status\":[{\"mediaSessionId\":\(mediaSessionIdToReturn),\"playbackRate\":1,\"playerState\":\"\(state)\"\(idle),\"currentTime\":0}]}"
        }

        private func reply(namespace: String, from: String, to: String, json: String, transport: MockCastTransport) {
            let respMsg = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: from,
                destinationId: to,
                namespace: namespace,
                payloadType: .string,
                payloadUtf8: json
            )
            if let framed = try? CastPacketFramer.frame(message: respMsg) {
                transport.simulateReceive(data: framed)
            }
        }

        /// Receiver-initiated message, e.g. unsolicited MEDIA_STATUS (requestId 0) or CLOSE.
        func pushFromReceiver(namespace: String, from: String = "mock-transport-001", json: String) {
            reply(namespace: namespace, from: from, to: "sender-0", json: json, transport: transport)
        }

        func pushMediaStatus(state: String, idleReason: String? = nil) {
            pushFromReceiver(namespace: CastNamespaces.media, json: mediaStatus(reqId: 0, state: state, idleReason: idleReason))
        }
    }
    final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _phases: [CastPhase] = []
        var phases: [CastPhase] { lock.lock(); defer { lock.unlock() }; return _phases }
        func record(_ p: CastPhase) { lock.lock(); defer { lock.unlock() }; _phases.append(p) }
    }
    // MARK: - Acceptance Criteria Tests

    func testCastMediaSendsLoadLiveStreamForM3U8() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 789

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        let m3u8URL = "http://192.168.1.10:8080/live/stream.m3u8"
        try await coordinator.castMedia(url: m3u8URL, to: device, title: "Live Channel")

        let isPlaying = await coordinator.isPlaying
        let mediaURL = await coordinator.currentMediaURL
        let mediaSessionId = await coordinator.mediaSessionId
        XCTAssertTrue(isPlaying)
        XCTAssertEqual(mediaURL, m3u8URL)
        XCTAssertEqual(mediaSessionId, 789)

        // Find LOAD message in sent messages
        let loadMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"LOAD\"") == true)
        }
        XCTAssertNotNil(loadMsg)
        XCTAssertEqual(loadMsg?.destinationId, "mock-transport-001")

        guard let payloadUtf8 = loadMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = json["media"] as? [String: Any] else {
            XCTFail("Missing or invalid media payload in LOAD message")
            return
        }

        XCTAssertEqual(media["streamType"] as? String, "LIVE")
        XCTAssertEqual(media["contentType"] as? String, "application/x-mpegURL")
        XCTAssertEqual(media["contentId"] as? String, m3u8URL)
        XCTAssertEqual(media["hlsVideoSegmentFormat"] as? String, "mpeg2_ts")

        let metadata = media["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["title"] as? String, "Live Channel")
        XCTAssertEqual(metadata?["metadataType"] as? Int, 0)
    }

    // MARK: - Cast session state machine

    func testHappyPathReachesPlayingThroughLaunchingAndLoading() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(transportFactory: { _ in mockDevice.transport })
        let recorder = PhaseRecorder()
        await coordinator.setOnPhaseChanged { recorder.record($0) }

        try await coordinator.castMedia(url: "http://192.168.1.10:8080/stream.m3u8", to: makeChromecastDevice())

        let phase = await coordinator.phase
        XCTAssertEqual(phase, .playing)
        XCTAssertEqual(recorder.phases, [.connecting, .launching, .loading, .playing])
    }
    func testCastMediaSendsLoadBufferedForMP4() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 456

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        let mp4URL = "http://192.168.1.10:8080/videos/SampleVideo.mp4"
        try await coordinator.castMedia(url: mp4URL, to: device)

        let isPlaying = await coordinator.isPlaying
        let mediaSessionId = await coordinator.mediaSessionId
        XCTAssertTrue(isPlaying)
        XCTAssertEqual(mediaSessionId, 456)

        let loadMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"LOAD\"") == true)
        }
        XCTAssertNotNil(loadMsg)

        guard let payloadUtf8 = loadMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = json["media"] as? [String: Any] else {
            XCTFail("Missing or invalid media payload in LOAD message")
            return
        }

        XCTAssertEqual(media["streamType"] as? String, "BUFFERED")
        XCTAssertEqual(media["contentType"] as? String, "video/mp4")
        XCTAssertEqual(media["contentId"] as? String, mp4URL)

        let metadata = media["metadata"] as? [String: Any]
        // Should infer filename if no title passed
        XCTAssertEqual(metadata?["title"] as? String, "SampleVideo.mp4")
    }

    func testPlayDispatchesPlayWithMediaSessionId() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 999

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        // Call play
        try await coordinator.play()

        let isPlaying = await coordinator.isPlaying
        XCTAssertTrue(isPlaying)

        let playMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"PLAY\"") == true)
        }
        XCTAssertNotNil(playMsg)
        XCTAssertEqual(playMsg?.destinationId, "mock-transport-001")

        guard let payloadUtf8 = playMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid PLAY payload")
            return
        }

        XCTAssertEqual(json["type"] as? String, "PLAY")
        XCTAssertEqual(json["mediaSessionId"] as? Int, 999)
    }

    func testPauseDispatchesPauseWithMediaSessionId() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 888

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        // Call pause
        try await coordinator.pause()

        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)

        let pauseMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"PAUSE\"") == true)
        }
        XCTAssertNotNil(pauseMsg)
        XCTAssertEqual(pauseMsg?.destinationId, "mock-transport-001")

        guard let payloadUtf8 = pauseMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid PAUSE payload")
            return
        }

        XCTAssertEqual(json["type"] as? String, "PAUSE")
        XCTAssertEqual(json["mediaSessionId"] as? Int, 888)
    }

    func testSeekDispatchesSeekWithCurrentTime() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 777

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        // Call seek
        try await coordinator.seek(seconds: 125.5)

        let currentPos = await coordinator.currentPositionSeconds
        XCTAssertEqual(currentPos, 125.5)

        let seekMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"SEEK\"") == true)
        }
        XCTAssertNotNil(seekMsg)
        XCTAssertEqual(seekMsg?.destinationId, "mock-transport-001")

        guard let payloadUtf8 = seekMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid SEEK payload")
            return
        }

        XCTAssertEqual(json["type"] as? String, "SEEK")
        XCTAssertEqual(json["mediaSessionId"] as? Int, 777)
        XCTAssertEqual(json["currentTime"] as? Double, 125.5)
    }

    func testStopDispatchesStopAndClosesSession() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.mediaSessionIdToReturn = 666

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        // Call stop
        try await coordinator.stop()

        let isPlaying = await coordinator.isPlaying
        let currentMediaURL = await coordinator.currentMediaURL
        let mediaSessionId = await coordinator.mediaSessionId
        XCTAssertFalse(isPlaying)
        XCTAssertNil(currentMediaURL)
        XCTAssertNil(mediaSessionId)

        let stopMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"STOP\"") == true)
        }
        XCTAssertNotNil(stopMsg)
        XCTAssertEqual(stopMsg?.destinationId, "mock-transport-001")

        guard let payloadUtf8 = stopMsg?.payloadUtf8,
              let data = payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid STOP payload")
            return
        }

        XCTAssertEqual(json["type"] as? String, "STOP")
        XCTAssertEqual(json["mediaSessionId"] as? Int, 666)

        // Transport should be closed after stop
        let transportConnected = mockDevice.transport.isConnected
        XCTAssertFalse(transportConnected)
    }

    func testSetVolumeClampsAndDispatchesSetVolumeToReceiver0() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )

        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        // Test normal volume
        try await coordinator.setVolume(level: 0.75)
        var volume = await coordinator.currentVolume
        XCTAssertEqual(volume, 0.75, accuracy: 0.001)

        var setVolMsg = mockDevice.sentMessages.last { msg in
            msg.namespace == CastNamespaces.receiver &&
            (msg.payloadUtf8?.contains("\"SET_VOLUME\"") == true)
        }
        XCTAssertNotNil(setVolMsg)
        XCTAssertEqual(setVolMsg?.destinationId, CastConstants.defaultReceiverId)

        if let payloadUtf8 = setVolMsg?.payloadUtf8,
           let data = payloadUtf8.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let volObj = json["volume"] as? [String: Any] {
            XCTAssertEqual(volObj["level"] as? Double, 0.75)
        } else {
            XCTFail("Invalid SET_VOLUME payload")
        }

        // Test clamp above 1.0
        try await coordinator.setVolume(level: 1.5)
        volume = await coordinator.currentVolume
        XCTAssertEqual(volume, 1.0, accuracy: 0.001)

        setVolMsg = mockDevice.sentMessages.last { msg in
            msg.namespace == CastNamespaces.receiver &&
            (msg.payloadUtf8?.contains("\"SET_VOLUME\"") == true)
        }
        if let payloadUtf8 = setVolMsg?.payloadUtf8,
           let data = payloadUtf8.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let volObj = json["volume"] as? [String: Any] {
            XCTAssertEqual(volObj["level"] as? Double, 1.0)
        }

        // Test clamp below 0.0
        try await coordinator.setVolume(level: -0.2)
        volume = await coordinator.currentVolume
        XCTAssertEqual(volume, 0.0, accuracy: 0.001)
    }

    final class HTTPRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        private var _url: URL?
        private var _body: Data?

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return _urls
        }

        var url: URL? {
            lock.lock()
            defer { lock.unlock() }
            return _url
        }

        var body: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _body
        }

        func record(url: URL, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            _urls.append(url)
            _url = url
            _body = body
        }
    }

    func testExistingDLNAPathContinuesToFunction() async throws {
        let recorder = HTTPRecorder()
        let coordinator = CastSessionCoordinator(httpPoster: { url, body in
            recorder.record(url: url, body: body)
        })
        let dlnaDevice = makeDLNADevice()
        let mediaURL = "http://192.168.1.10:8080/video.mp4"

        try await coordinator.castMedia(url: mediaURL, to: dlnaDevice)

        var isPlaying = await coordinator.isPlaying
        var currentURL = await coordinator.currentMediaURL
        XCTAssertTrue(isPlaying)
        XCTAssertEqual(currentURL, mediaURL)

        try await coordinator.pause()
        isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)

        try await coordinator.play()
        isPlaying = await coordinator.isPlaying
        XCTAssertTrue(isPlaying)

        try await coordinator.seek(seconds: 60)
        let pos = await coordinator.currentPositionSeconds
        XCTAssertEqual(pos, 60)

        try await coordinator.stop()
        isPlaying = await coordinator.isPlaying
        currentURL = await coordinator.currentMediaURL
        XCTAssertFalse(isPlaying)
        XCTAssertNil(currentURL)

        XCTAssertFalse(recorder.urls.isEmpty)
    }

    func testExistingRokuPathContinuesToFunction() async throws {
        let recorder = HTTPRecorder()
        let coordinator = CastSessionCoordinator(httpPoster: { url, body in
            recorder.record(url: url, body: body)
        })
        let rokuDevice = makeRokuDevice()
        let mediaURL = "http://192.168.1.10:8080/video.mp4"

        try await coordinator.castMedia(url: mediaURL, to: rokuDevice)

        var isPlaying = await coordinator.isPlaying
        var currentURL = await coordinator.currentMediaURL
        XCTAssertTrue(isPlaying)
        XCTAssertEqual(currentURL, mediaURL)

        try await coordinator.pause()
        isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)

        try await coordinator.play()
        isPlaying = await coordinator.isPlaying
        XCTAssertTrue(isPlaying)

        try await coordinator.stop()
        isPlaying = await coordinator.isPlaying
        currentURL = await coordinator.currentMediaURL
        XCTAssertFalse(isPlaying)
        XCTAssertNil(currentURL)

        XCTAssertFalse(recorder.urls.isEmpty)
    }

    // MARK: - Ticket #16 UI State Centralization and Auto-Reconnection Tests

    private func makeNetworkHelper() -> NetworkInterfaceHelper {
        let mockProvider = MockNetworkInterfaceProvider(interfaces: [
            NetworkInterface(name: "en0", address: "192.168.1.10", isIPv4: true, isUp: true, isLoopback: false)
        ])
        return NetworkInterfaceHelper(provider: mockProvider)
    }

    final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [CastConnectionState] = []
        var states: [CastConnectionState] {
            lock.lock()
            defer { lock.unlock() }
            return _states
        }
        func record(_ state: CastConnectionState) {
            lock.lock()
            defer { lock.unlock() }
            _states.append(state)
        }
    }

    func testSelectDeviceUpdatesSelectedDeviceAndTransitionsState() async throws {
        let coordinator = CastSessionCoordinator()
        let state = await coordinator.connectionState
        XCTAssertEqual(state, .disconnected)
        let active = await coordinator.selectedDevice
        XCTAssertNil(active)

        let device = makeChromecastDevice()
        await coordinator.selectDevice(device)
        let selected = await coordinator.selectedDevice
        XCTAssertEqual(selected, device)
        let stateAfterSelect = await coordinator.connectionState
        XCTAssertEqual(stateAfterSelect, .disconnected)

        await coordinator.selectDevice(nil)
        let deselected = await coordinator.selectedDevice
        XCTAssertNil(deselected)
        let stateAfterNil = await coordinator.connectionState
        XCTAssertEqual(stateAfterNil, .disconnected)
    }

    func testConnectTransitionsDisconnectedToConnectingToReady() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let recorder = StateRecorder()
        await coordinator.setOnConnectionStateChanged { state in
            recorder.record(state)
        }

        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let finalState = await coordinator.connectionState
        XCTAssertEqual(finalState, .ready)
        let selected = await coordinator.selectedDevice
        XCTAssertEqual(selected, device)

        let states = recorder.states
        XCTAssertTrue(states.contains(.connecting))
        XCTAssertTrue(states.contains(.ready))
    }

    func testStartScreenMirrorStartsServerCastsStreamAndTransitionsToStreaming() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let mirrorStream = MirrorStream(port: 0)
        let netHelper = makeNetworkHelper()

        let streamURL = try await coordinator.startScreenMirror(
            mirrorStream: mirrorStream,
            networkHelper: netHelper
        )

        let state = await coordinator.connectionState
        XCTAssertEqual(state, .streaming)
        let isStreaming = await mirrorStream.isStreaming
        XCTAssertTrue(isStreaming)
        let isPlaying = await coordinator.isPlaying
        XCTAssertTrue(isPlaying)
        XCTAssertTrue(streamURL.contains(".m3u8"))

        // Verify LOAD was sent to Chromecast
        let loadMsg = mockDevice.sentMessages.first { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"LOAD\"") == true)
        }
        XCTAssertNotNil(loadMsg)
        XCTAssertTrue(loadMsg?.payloadUtf8?.contains("Screen Mirror") == true)

        await mirrorStream.stop()
    }

    func testStopScreenMirrorStopsPlaybackAndServerAndTransitionsToReadyOrDisconnected() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let mirrorStream = MirrorStream(port: 0)
        let netHelper = makeNetworkHelper()
        _ = try await coordinator.startScreenMirror(
            mirrorStream: mirrorStream,
            networkHelper: netHelper
        )

        try await coordinator.stopScreenMirror(mirrorStream: mirrorStream)

        let isStreaming = await mirrorStream.isStreaming
        XCTAssertFalse(isStreaming)
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
        let state = await coordinator.connectionState
        XCTAssertEqual(state, .ready)

        // If device is deselected and stopped
        await coordinator.selectDevice(nil)
        let stateAfterDeselect = await coordinator.connectionState
        XCTAssertEqual(stateAfterDeselect, .disconnected)
    }

    final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            _count += 1
        }
    }

    func testAutoReconnectionSuccessOnUnexpectedSocketDrop() async throws {
        let mockDevice = MockChromecastDevice()
        let counter = AtomicCounter()

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in
                counter.increment()
                return mockDevice.transport
            },
            reconnectDelay: 0
        )
        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let mirrorStream = MirrorStream(port: 0)
        let netHelper = makeNetworkHelper()
        _ = try await coordinator.startScreenMirror(
            mirrorStream: mirrorStream,
            networkHelper: netHelper
        )

        let recorder = StateRecorder()
        await coordinator.setOnConnectionStateChanged { state in
            recorder.record(state)
        }

        // Trigger unexpected disconnect
        await coordinator.handleUnexpectedDisconnection()

        let finalState = await coordinator.connectionState
        XCTAssertEqual(finalState, .streaming)
        let isReconnecting = await coordinator.isReconnecting
        XCTAssertFalse(isReconnecting)
        let isPlaying = await coordinator.isPlaying
        XCTAssertTrue(isPlaying)

        let states = recorder.states
        XCTAssertTrue(states.contains(.connecting))
        XCTAssertTrue(states.contains(.streaming))

        await mirrorStream.stop()
    }

    func testAutoReconnectionFailureTearsDownServerAndSetsErrorMessage() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport },
            reconnectDelay: 0
        )
        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let mirrorStream = MirrorStream(port: 0)
        let netHelper = makeNetworkHelper()
        _ = try await coordinator.startScreenMirror(
            mirrorStream: mirrorStream,
            networkHelper: netHelper
        )

        // Make future connections fail
        mockDevice.transport.shouldFailConnection = CastTransportError.connectionFailed("Host unreachable")

        await coordinator.handleUnexpectedDisconnection()

        let finalState = await coordinator.connectionState
        XCTAssertTrue(finalState == .disconnected || finalState == .error("TV disconnected. Streaming stopped."))
        let errorMessage = await coordinator.errorMessage
        XCTAssertEqual(errorMessage, "TV disconnected. Streaming stopped.")
        let isReconnecting = await coordinator.isReconnecting
        XCTAssertFalse(isReconnecting)

        // Verify local server was torn down (no orphaned server)
        let isStreaming = await mirrorStream.isStreaming
        XCTAssertFalse(isStreaming)
    }

    func testAutoReconnectionDoesNotLoopInfinitely() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.transport.shouldFailConnection = CastTransportError.connectionFailed("No network")

        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let device = makeChromecastDevice()
        // Force state to streaming to simulate active stream drop
        await coordinator.selectDevice(device)
        // Manually attempt handleUnexpectedDisconnection when not in streaming state: does nothing
        await coordinator.handleUnexpectedDisconnection()
        let state = await coordinator.connectionState
        XCTAssertEqual(state, .disconnected)
        let isReconnecting = await coordinator.isReconnecting
        XCTAssertFalse(isReconnecting)
    }

    func testHandleUnexpectedDisconnectionWhileReadyTransitionsToDisconnectedAndResetsClient() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let device = makeChromecastDevice()
        try await coordinator.connect(to: device)

        let readyState = await coordinator.connectionState
        XCTAssertEqual(readyState, .ready)
        let clientBefore = await coordinator.castClient
        XCTAssertNotNil(clientBefore)

        // Drop while ready
        await coordinator.handleUnexpectedDisconnection()

        let stateAfter = await coordinator.connectionState
        XCTAssertEqual(stateAfter, .disconnected)
        let clientAfter = await coordinator.castClient
        XCTAssertNil(clientAfter)
    }

    func testHandleUnexpectedDisconnectionPreservesMediaTitle() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport },
            reconnectDelay: 0
        )
        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/custom.mp4", to: device, title: "Epic Movie")

        let titleBefore = await coordinator.currentMediaTitle
        XCTAssertEqual(titleBefore, "Epic Movie")

        // Trigger unexpected disconnect while streaming
        await coordinator.handleUnexpectedDisconnection()

        let titleAfter = await coordinator.currentMediaTitle
        XCTAssertEqual(titleAfter, "Epic Movie")

        let loadMsgs = mockDevice.sentMessages.filter { msg in
            msg.namespace == CastNamespaces.media &&
            (msg.payloadUtf8?.contains("\"LOAD\"") == true)
        }
        XCTAssertFalse(loadMsgs.isEmpty)
        for msg in loadMsgs {
            XCTAssertTrue(msg.payloadUtf8?.contains("Epic Movie") == true)
            XCTAssertFalse(msg.payloadUtf8?.contains("Screen Mirror") == true)
        }
    }

    func testStartScreenMirrorWithoutWiFiThrowsTypedErrorAndCastsNothing() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        try await coordinator.connect(to: makeChromecastDevice())

        let mirrorStream = MirrorStream(port: 0)
        let noWiFiHelper = NetworkInterfaceHelper(provider: MockNetworkInterfaceProvider(interfaces: []))

        do {
            _ = try await coordinator.startScreenMirror(
                mirrorStream: mirrorStream,
                networkHelper: noWiFiHelper
            )
            XCTFail("Expected noWiFiIPv4Address")
        } catch {
            XCTAssertEqual(error as? StreamURLError, .noWiFiIPv4Address)
        }

        let errorMsg = await coordinator.errorMessage
        XCTAssertTrue(errorMsg?.contains("Wi-Fi") == true)
        let isStreaming = await mirrorStream.isStreaming
        XCTAssertFalse(isStreaming)
        let currentURL = await coordinator.currentMediaURL
        XCTAssertNil(currentURL)
    }

    func testStopSetsStateToDisconnected() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in mockDevice.transport }
        )
        let device = makeChromecastDevice()
        try await coordinator.castMedia(url: "http://example.com/video.mp4", to: device)

        let stateBefore = await coordinator.connectionState
        XCTAssertEqual(stateBefore, .streaming)

        try await coordinator.stop()

        let stateAfter = await coordinator.connectionState
        XCTAssertEqual(stateAfter, .disconnected)
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
    }

    // MARK: - Failure and receiver-driven transitions

    private func loadMessages(_ device: MockChromecastDevice) -> [CastMessage] {
        device.sentMessages.filter { $0.namespace == CastNamespaces.media && ($0.payloadUtf8?.contains("\"LOAD\"") == true) }
    }

    private func waitForPhase(_ coordinator: CastSessionCoordinator, _ expected: CastPhase, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await coordinator.phase == expected { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await coordinator.phase == expected
    }

    private func castAndExpectFailure(_ mockDevice: MockChromecastDevice, file: StaticString = #filePath, line: UInt = #line) async -> (CastSessionCoordinator, Error?) {
        let coordinator = CastSessionCoordinator(transportFactory: { _ in mockDevice.transport })
        do {
            try await coordinator.castMedia(url: "http://192.168.1.10:8080/stream.m3u8", to: makeChromecastDevice())
            XCTFail("Expected castMedia to throw", file: file, line: line)
            return (coordinator, nil)
        } catch {
            return (coordinator, error)
        }
    }

    func testLoadFailedReachesFailedWithReceiverReason() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.loadBehavior = .loadFailed("MEDIA_UNSUPPORTED")
        let (coordinator, _) = await castAndExpectFailure(mockDevice)

        let phase = await coordinator.phase
        guard case .failed(let failure) = phase else { return XCTFail("Expected failed, got \(phase)") }
        XCTAssertEqual(failure, .loadFailed("MEDIA_UNSUPPORTED"))
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
    }

    func testInvalidRequestReachesFailedWithReceiverReason() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.loadBehavior = .invalidRequest("INVALID_COMMAND")
        let (coordinator, _) = await castAndExpectFailure(mockDevice)

        let phase = await coordinator.phase
        XCTAssertEqual(phase, .failed(.loadFailed("INVALID_COMMAND")))
    }

    func testIdleReasonErrorInLoadResponseReachesFailed() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.loadBehavior = .idleError
        let (coordinator, _) = await castAndExpectFailure(mockDevice)

        let phase = await coordinator.phase
        XCTAssertEqual(phase, .failed(.receiverError("ERROR")))
    }

    func testUnsolicitedMediaStatusMovesPhase() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(transportFactory: { _ in mockDevice.transport })
        try await coordinator.castMedia(url: "http://192.168.1.10:8080/stream.m3u8", to: makeChromecastDevice())

        mockDevice.pushMediaStatus(state: "BUFFERING")
        let buffering = await waitForPhase(coordinator, .buffering)
        XCTAssertTrue(buffering)

        mockDevice.pushMediaStatus(state: "PLAYING")
        let playing = await waitForPhase(coordinator, .playing)
        XCTAssertTrue(playing)

        mockDevice.pushMediaStatus(state: "IDLE", idleReason: "ERROR")
        let failed = await waitForPhase(coordinator, .failed(.receiverError("ERROR")))
        XCTAssertTrue(failed)
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
    }

    func testReceiverCloseEndsSessionWithStoppedOnTVAndDoesNotReconnect() async throws {
        let mockDevice = MockChromecastDevice()
        let coordinator = CastSessionCoordinator(transportFactory: { _ in mockDevice.transport }, reconnectDelay: 0)
        try await coordinator.castMedia(url: "http://192.168.1.10:8080/stream.m3u8", to: makeChromecastDevice())

        mockDevice.pushFromReceiver(namespace: CastNamespaces.connection, json: "{\"type\":\"CLOSE\"}")

        let ended = await waitForPhase(coordinator, .ended("stopped on TV"))
        XCTAssertTrue(ended)
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
        XCTAssertEqual(loadMessages(mockDevice).count, 1)
    }

    func testConnectTimeoutReachesFailedWithinTimeout() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.transport.hangConnection = true
        let coordinator = CastSessionCoordinator(transportFactory: { _ in mockDevice.transport }, connectTimeout: 0.3)

        let started = Date()
        do {
            try await coordinator.connect(to: makeChromecastDevice())
            XCTFail("Expected connect to time out")
        } catch {
            XCTAssertEqual(error as? CastFailure, .connectTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        let phase = await coordinator.phase
        XCTAssertEqual(phase, .failed(.connectTimeout))
    }

    func testTransportWaitingReachesFailedWithPermissionError() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.transport.shouldFailConnection = CastTransportError.waiting("Local network prohibited")
        let (coordinator, _) = await castAndExpectFailure(mockDevice)

        let phase = await coordinator.phase
        XCTAssertEqual(phase, .failed(.localNetworkPermission("Local network prohibited")))
        let message = await coordinator.errorMessage
        XCTAssertTrue(message?.contains("Local Network") == true)
    }

    func testCastV2ConnectionFailureIsFailureNotSuccess() async throws {
        let mockDevice = MockChromecastDevice()
        mockDevice.transport.shouldFailConnection = CastTransportError.connectionFailed("TLS handshake timeout")
        let (coordinator, _) = await castAndExpectFailure(mockDevice)

        let phase = await coordinator.phase
        guard case .failed(.connectionFailed) = phase else { return XCTFail("Expected failed, got \(phase)") }
        let isPlaying = await coordinator.isPlaying
        XCTAssertFalse(isPlaying)
        let state = await coordinator.connectionState
        guard case .error = state else { return XCTFail("Expected error state, got \(state)") }
    }

    func testReconnectAttemptsAreBounded() async throws {
        let mockDevice = MockChromecastDevice()
        let counter = AtomicCounter()
        let coordinator = CastSessionCoordinator(
            transportFactory: { _ in counter.increment(); return mockDevice.transport },
            maxReconnectAttempts: 2,
            reconnectDelay: 0
        )
        try await coordinator.castMedia(url: "http://192.168.1.10:8080/stream.m3u8", to: makeChromecastDevice())
        XCTAssertEqual(counter.count, 1)

        mockDevice.transport.shouldFailConnection = CastTransportError.connectionFailed("Host unreachable")
        await coordinator.handleUnexpectedDisconnection()

        XCTAssertEqual(counter.count, 3)
        let phase = await coordinator.phase
        XCTAssertEqual(phase, .failed(.reconnectFailed))
    }}

