import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CastConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
    case streaming
    case error(String)
}

public actor CastSessionCoordinator {
    public typealias DialHTTPPoster = @Sendable (URL, Data?) async throws -> Void

    public private(set) var connectionState: CastConnectionState = .disconnected
    public private(set) var selectedDevice: DiscoveredDevice?
    public var activeDevice: DiscoveredDevice? { selectedDevice }
    public private(set) var isReconnecting: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var activeStreamController: StreamController?

    public private(set) var currentMediaURL: String?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentPositionSeconds: Double = 0
    public private(set) var mediaSessionId: Int?
    public private(set) var currentVolume: Double = 1.0
    public private(set) var castClient: CastV2Client?

    public var onConnectionStateChanged: (@Sendable (CastConnectionState) -> Void)?

    private var activeTransportId: String?
    private let customCastClient: CastV2Client?
    private let transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)?
    private let dialHTTPPoster: DialHTTPPoster?

    public init(
        castClient: CastV2Client? = nil,
        transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)? = nil,
        dialHTTPPoster: DialHTTPPoster? = nil
    ) {
        self.customCastClient = castClient
        self.castClient = castClient
        #if canImport(Network)
        self.transportFactory = transportFactory ?? { _ in NWConnectionCastTransport() }
        #else
        self.transportFactory = transportFactory
        #endif
        self.dialHTTPPoster = dialHTTPPoster
    }

    public init(
        castClient: CastV2Client? = nil,
        transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)? = nil,
        dialHTTPPoster: (@Sendable (URL) async throws -> Void)?
    ) {
        if let poster = dialHTTPPoster {
            self.init(
                castClient: castClient,
                transportFactory: transportFactory,
                dialHTTPPoster: { @Sendable (url: URL, _: Data?) async throws in
                    try await poster(url)
                }
            )
        } else {
            self.init(
                castClient: castClient,
                transportFactory: transportFactory,
                dialHTTPPoster: Optional<DialHTTPPoster>.none
            )
        }
    }

    // MARK: - State Notification

    public func setOnConnectionStateChanged(_ handler: (@Sendable (CastConnectionState) -> Void)?) {
        self.onConnectionStateChanged = handler
    }

    private func updateConnectionState(_ newState: CastConnectionState) {
        self.connectionState = newState
        if case .error(let msg) = newState {
            self.errorMessage = msg
        }
        self.onConnectionStateChanged?(newState)
    }

    // MARK: - Device Selection

    public func selectDevice(_ device: DiscoveredDevice?) async {
        if let previous = self.selectedDevice, previous != device {
            if self.isPlaying || self.connectionState != .disconnected {
                try? await self.stop()
            }
        }
        self.selectedDevice = device
        self.errorMessage = nil
        updateConnectionState(.disconnected)
    }

    // MARK: - Connection & Preparation

    public func connect(to device: DiscoveredDevice) async throws {
        self.selectedDevice = device
        self.errorMessage = nil
        updateConnectionState(.connecting)

        switch device.type {
        case .chromecast:
            do {
                let client = try await getOrCreateCastClient(for: device)
                let isConnected = await client.isConnected
                if !isConnected {
                    let port = device.port == 0 ? CastConstants.defaultPort : device.port
                    try await client.connect(host: device.ipAddress, port: port)
                }

                let transportId: String
                if let existingTransportId = await client.activeTransportId {
                    transportId = existingTransportId
                } else {
                    let launch = try await client.launchReceiver(appId: CastConstants.defaultAppId)
                    transportId = launch.transportId
                }
                self.activeTransportId = transportId
                updateConnectionState(.ready)
            } catch {
                let dialURLString = "http://\(device.ipAddress):8008/apps/\(CastConstants.defaultAppId)"
                if let dialURL = URL(string: dialURLString) {
                    do {
                        try await sendHTTPPost(url: dialURL)
                        updateConnectionState(.ready)
                    } catch {
                        let msg = "Failed to connect to \(device.name): \(error.localizedDescription)"
                        self.errorMessage = msg
                        updateConnectionState(.error(msg))
                        throw error
                    }
                } else {
                    let msg = "Failed to connect to \(device.name): \(error.localizedDescription)"
                    self.errorMessage = msg
                    updateConnectionState(.error(msg))
                    throw error
                }
            }

        case .roku, .dlna, .web:
            updateConnectionState(.ready)
        }
    }

    public func connect() async throws {
        guard let device = selectedDevice else {
            throw CastTransportError.notConnected
        }
        try await connect(to: device)
    }

    // MARK: - Screen Mirroring Lifecycle

    @discardableResult
    public func startScreenMirror(
        streamController: StreamController,
        networkHelper: NetworkInterfaceHelper = .shared,
        port: Int? = nil
    ) async throws -> String {
        self.activeStreamController = streamController
        let boundPort = try await streamController.start()
        let portToUse = UInt16(port ?? Int(boundPort))
        let (resolvedURL, _) = networkHelper.resolveStreamURL(port: portToUse, path: "stream.m3u8")
        self.currentMediaURL = resolvedURL

        if let device = selectedDevice {
            try await castMedia(url: resolvedURL, to: device, title: "Screen Mirror")
        }

        updateConnectionState(.streaming)
        return resolvedURL
    }

    public func stopScreenMirror(streamController: StreamController) async throws {
        try? await self.stop()
        await streamController.stop()
        self.activeStreamController = nil
        if selectedDevice != nil {
            updateConnectionState(.ready)
        } else {
            updateConnectionState(.disconnected)
        }
    }

    // MARK: - Media Casting & Playback

    public func castMedia(url: String, to device: DiscoveredDevice, title: String? = nil) async throws {
        self.selectedDevice = device
        self.currentMediaURL = url
        self.isPlaying = true
        self.currentPositionSeconds = 0

        switch device.type {
        case .roku:
            let launchURL = RokuECPClient.buildLaunchURL(deviceIP: device.ipAddress, mediaURL: url)
            try? await sendHTTPPost(url: launchURL)
            updateConnectionState(.streaming)

        case .dlna:
            let soap = UPnPClient.generateSetAVTransportURIPayload(mediaURL: url)
            await sendSOAP(action: "SetAVTransportURI", payload: soap, on: device)
            try? await play()
            updateConnectionState(.streaming)

        case .chromecast:
            do {
                try await castChromecastV2(url: url, to: device, title: title)
                updateConnectionState(.streaming)
            } catch {
                let dialURLString = "http://\(device.ipAddress):8008/apps/\(CastConstants.defaultAppId)"
                if let dialURL = URL(string: dialURLString) {
                    let body = Data(url.utf8)
                    try? await sendHTTPPost(url: dialURL, body: body)
                }
                self.selectedDevice = device
                self.currentMediaURL = url
                self.isPlaying = true
                self.currentPositionSeconds = 0
                updateConnectionState(.streaming)
            }

        case .web:
            updateConnectionState(.streaming)
        }
    }

    public func play() async throws {
        guard let device = selectedDevice else { return }
        self.isPlaying = true

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play")
            try? await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generatePlayPayload()
            await sendSOAP(action: "Play", payload: soap, on: device)

        case .chromecast:
            if let mediaSessionId = self.mediaSessionId,
               let transportId = await castClient?.activeTransportId ?? self.activeTransportId {
                let payload: [String: Any] = [
                    "type": "PLAY",
                    "mediaSessionId": mediaSessionId
                ]
                try? await sendCastPayload(payload, namespace: CastNamespaces.media, destinationId: transportId)
            }

        case .web:
            break
        }
    }

    public func pause() async throws {
        guard let device = selectedDevice else { return }
        self.isPlaying = false

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play")
            try? await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generatePausePayload()
            await sendSOAP(action: "Pause", payload: soap, on: device)

        case .chromecast:
            if let mediaSessionId = self.mediaSessionId,
               let transportId = await castClient?.activeTransportId ?? self.activeTransportId {
                let payload: [String: Any] = [
                    "type": "PAUSE",
                    "mediaSessionId": mediaSessionId
                ]
                try? await sendCastPayload(payload, namespace: CastNamespaces.media, destinationId: transportId)
            }

        case .web:
            break
        }
    }

    public func stop() async throws {
        guard let device = selectedDevice else {
            updateConnectionState(.disconnected)
            return
        }
        self.isPlaying = false
        self.currentMediaURL = nil

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Back")
            try? await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generateStopPayload()
            await sendSOAP(action: "Stop", payload: soap, on: device)

        case .chromecast:
            if let client = self.castClient {
                if let mediaSessionId = self.mediaSessionId,
                   let transportId = await client.activeTransportId ?? self.activeTransportId {
                    let payload: [String: Any] = [
                        "type": "STOP",
                        "mediaSessionId": mediaSessionId
                    ]
                    try? await sendCastPayload(payload, namespace: CastNamespaces.media, destinationId: transportId)
                }
                await client.disconnect()
            }
            if self.customCastClient == nil {
                self.castClient = nil
            }
            self.mediaSessionId = nil
            self.activeTransportId = nil

        case .web:
            break
        }

        if selectedDevice != nil {
            updateConnectionState(.ready)
        } else {
            updateConnectionState(.disconnected)
        }
    }

    public func seek(seconds: Double) async throws {
        guard let device = selectedDevice else { return }
        self.currentPositionSeconds = seconds

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let timeString = String(format: "%02d:%02d:%02d", hours, minutes, secs)

        switch device.type {
        case .dlna:
            let soap = UPnPClient.generateSeekPayload(targetTime: timeString)
            await sendSOAP(action: "Seek", payload: soap, on: device)

        case .chromecast:
            if let mediaSessionId = self.mediaSessionId,
               let transportId = await castClient?.activeTransportId ?? self.activeTransportId {
                let payload: [String: Any] = [
                    "type": "SEEK",
                    "mediaSessionId": mediaSessionId,
                    "currentTime": seconds
                ]
                try? await sendCastPayload(payload, namespace: CastNamespaces.media, destinationId: transportId)
            }

        case .roku, .web:
            break
        }
    }

    public func setVolume(level: Double) async throws {
        let clamped = max(0.0, min(1.0, level))
        self.currentVolume = clamped

        guard let device = selectedDevice, device.type == .chromecast else { return }
        let payload: [String: Any] = [
            "type": "SET_VOLUME",
            "volume": [
                "level": clamped
            ]
        ]
        try? await sendCastPayload(
            payload,
            namespace: CastNamespaces.receiver,
            destinationId: CastConstants.defaultReceiverId
        )
    }

    // MARK: - Auto-Reconnection

    public func handleUnexpectedDisconnection() async {
        guard connectionState == .streaming else { return }
        guard !isReconnecting else { return }

        isReconnecting = true
        updateConnectionState(.connecting)

        guard let device = selectedDevice, let mediaURL = currentMediaURL else {
            await handleReconnectionFailure(message: "TV disconnected. Streaming stopped.")
            return
        }

        do {
            if let client = self.castClient {
                await client.disconnect()
                if self.customCastClient == nil {
                    self.castClient = nil
                }
            }
            self.activeTransportId = nil
            self.mediaSessionId = nil

            try await castChromecastV2(url: mediaURL, to: device, title: "Screen Mirror")

            self.isReconnecting = false
            self.errorMessage = nil
            updateConnectionState(.streaming)
        } catch {
            await handleReconnectionFailure(message: "TV disconnected. Streaming stopped.")
        }
    }

    private func handleReconnectionFailure(message: String) async {
        self.isReconnecting = false
        self.errorMessage = message
        self.isPlaying = false
        self.currentMediaURL = nil
        self.mediaSessionId = nil
        self.activeTransportId = nil

        if let controller = self.activeStreamController {
            await controller.stop()
            self.activeStreamController = nil
        }

        updateConnectionState(.error(message))
    }

    // MARK: - Chromecast Helpers

    private func getOrCreateCastClient(for device: DiscoveredDevice) async throws -> CastV2Client {
        let client: CastV2Client
        if let custom = self.customCastClient {
            client = custom
        } else if let existing = self.castClient, await existing.isConnected {
            client = existing
        } else if let factory = self.transportFactory {
            let transport = factory(device)
            client = CastV2Client(transport: transport)
            self.castClient = client
        } else {
            throw CastTransportError.connectionFailed("No CastTransport factory available for Chromecast")
        }

        await client.setOnDisconnect { [weak self] in
            await self?.handleUnexpectedDisconnection()
        }
        return client
    }

    private func castChromecastV2(url: String, to device: DiscoveredDevice, title: String?) async throws {
        let client = try await getOrCreateCastClient(for: device)

        let isConnected = await client.isConnected
        if !isConnected {
            let port = device.port == 0 ? CastConstants.defaultPort : device.port
            try await client.connect(host: device.ipAddress, port: port)
        }

        let transportId: String
        if let existingTransportId = await client.activeTransportId {
            transportId = existingTransportId
        } else {
            let launch = try await client.launchReceiver(appId: CastConstants.defaultAppId)
            transportId = launch.transportId
        }
        self.activeTransportId = transportId

        let lowercasedURL = url.lowercased()
        let streamType: String
        let contentType: String
        if lowercasedURL.contains(".m3u8") {
            streamType = "LIVE"
            contentType = "application/x-mpegURL"
        } else {
            streamType = "BUFFERED"
            contentType = "video/mp4"
        }

        let resolvedTitle: String
        if let title = title, !title.isEmpty {
            resolvedTitle = title
        } else if let parsed = URL(string: url), !parsed.lastPathComponent.isEmpty, parsed.lastPathComponent != "/" {
            resolvedTitle = parsed.lastPathComponent
        } else {
            resolvedTitle = "Cast Stream"
        }

        let loadPayload: [String: Any] = [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": 0,
            "media": [
                "contentId": url,
                "streamType": streamType,
                "contentType": contentType,
                "metadata": [
                    "title": resolvedTitle,
                    "metadataType": 0
                ]
            ]
        ]

        let response = try await client.request(
            namespace: CastNamespaces.media,
            destinationId: transportId,
            payload: loadPayload
        )

        if let sessionId = extractMediaSessionId(from: response) {
            self.mediaSessionId = sessionId
        }

        self.selectedDevice = device
        self.currentMediaURL = url
        self.isPlaying = true
        self.currentPositionSeconds = 0
    }

    private func extractMediaSessionId(from response: [String: Any]) -> Int? {
        if let statusList = response["status"] as? [[String: Any]],
           let first = statusList.first {
            if let id = first["mediaSessionId"] as? Int { return id }
            if let num = first["mediaSessionId"] as? NSNumber { return num.intValue }
        }
        if let statusDict = response["status"] as? [String: Any] {
            if let id = statusDict["mediaSessionId"] as? Int { return id }
            if let num = statusDict["mediaSessionId"] as? NSNumber { return num.intValue }
        }
        if let id = response["mediaSessionId"] as? Int { return id }
        if let num = response["mediaSessionId"] as? NSNumber { return num.intValue }
        return nil
    }

    private func sendCastPayload(_ payload: [String: Any], namespace: String, destinationId: String) async throws {
        guard let client = self.castClient else { return }
        var fullPayload = payload
        let reqId = await client.nextRequestId()
        fullPayload["requestId"] = reqId
        let data = try JSONSerialization.data(withJSONObject: fullPayload)
        guard let str = String(data: data, encoding: .utf8) else { return }
        let sourceId = client.clientSourceId
        let msg = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: sourceId,
            destinationId: destinationId,
            namespace: namespace,
            payloadType: .string,
            payloadUtf8: str
        )
        try await client.send(message: msg)
    }

    // MARK: - Networking

    private func sendSOAP(action: String, payload: String, on device: DiscoveredDevice) async {
        guard let controlURL = device.controlURL else { return }
        if let poster = self.dialHTTPPoster {
            try? await poster(controlURL, Data(payload.utf8))
            return
        }
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(payload.utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendHTTPPost(url: URL, body: Data? = nil) async throws {
        if let poster = self.dialHTTPPoster {
            try await poster(url, body)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body = body {
            request.httpBody = body
        }
        _ = try await URLSession.shared.data(for: request)
    }
}
