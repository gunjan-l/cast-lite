import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coarse connection state kept for the app UI. Derived from `CastPhase`, never set independently.
public enum CastConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
    case streaming
    case error(String)
}

/// Why a Cast session failed. Carries the receiver's or transport's own reason.
public enum CastFailure: Error, Equatable, Sendable {
    case connectTimeout
    /// Transport reported `.waiting`; almost always missing Local Network permission.
    case localNetworkPermission(String)
    case connectionFailed(String)
    case launchFailed(String)
    /// LOAD_FAILED or INVALID_REQUEST, with the receiver's reason.
    case loadFailed(String)
    /// MEDIA_STATUS idleReason ERROR (or similar receiver-side playback error).
    case receiverError(String)
    case reconnectFailed
    /// The phone has no Wi-Fi address the TV could fetch the stream from.
    case networkUnavailable(String)

    public var message: String {
        switch self {
        case .connectTimeout:
            return "Timed out connecting to the TV."
        case .localNetworkPermission(let reason):
            return "Local Network access is required to reach the TV (\(reason)). Enable it in Settings."
        case .connectionFailed(let reason):
            return "Failed to connect to the TV: \(reason)"
        case .launchFailed(let reason):
            return "The TV could not start the receiver: \(reason)"
        case .loadFailed(let reason):
            return "The TV rejected the stream: \(reason)"
        case .receiverError(let reason):
            return "The TV reported a playback error: \(reason)"
        case .reconnectFailed:
            return "TV disconnected. Streaming stopped."
        case .networkUnavailable(let reason):
            return reason
        }
    }
}

extension CastFailure: LocalizedError {
    public var errorDescription: String? { message }
}

/// Explicit lifecycle of a Cast session. The app's status UI and `/debug` render from this.
public enum CastPhase: Equatable, Sendable {
    case idle
    case connecting
    case launching
    case loading
    case buffering
    case playing
    case ended(String)
    case failed(CastFailure)
}

public actor CastSessionCoordinator {
    public typealias HTTPPoster = @Sendable (URL, Data?) async throws -> Void

    public static let defaultConnectTimeout: TimeInterval = 8
    public static let defaultMaxReconnectAttempts = 3
    public static let defaultReconnectDelay: TimeInterval = 1
    public static let stoppedOnTV = "stopped on TV"

    public private(set) var phase: CastPhase = .idle
    public var connectionState: CastConnectionState {
        switch phase {
        case .idle: return receiverReady ? .ready : .disconnected
        case .connecting, .launching, .loading: return .connecting
        case .buffering, .playing: return .streaming
        case .ended: return .disconnected
        case .failed(let failure): return .error(failure.message)
        }
    }
    public private(set) var selectedDevice: DiscoveredDevice?
    public var activeDevice: DiscoveredDevice? { selectedDevice }
    public private(set) var isReconnecting: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var activeMirrorStream: MirrorStream?

    public private(set) var currentMediaURL: String?
    public private(set) var currentMediaTitle: String?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentPositionSeconds: Double = 0
    public private(set) var mediaSessionId: Int?
    public private(set) var currentVolume: Double = 1.0
    public private(set) var castClient: CastV2Client?

    public var onConnectionStateChanged: (@Sendable (CastConnectionState) -> Void)?
    public var onPhaseChanged: (@Sendable (CastPhase) -> Void)?

    private var receiverReady = false
    private var activeTransportId: String?
    private var activeTransport: CastTransport?
    private let customCastClient: CastV2Client?
    private let transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)?
    private let httpPoster: HTTPPoster?
    private let connectTimeout: TimeInterval
    private let maxReconnectAttempts: Int
    private let reconnectDelay: TimeInterval

    public init(
        castClient: CastV2Client? = nil,
        transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)? = nil,
        httpPoster: HTTPPoster? = nil,
        connectTimeout: TimeInterval = CastSessionCoordinator.defaultConnectTimeout,
        maxReconnectAttempts: Int = CastSessionCoordinator.defaultMaxReconnectAttempts,
        reconnectDelay: TimeInterval = CastSessionCoordinator.defaultReconnectDelay
    ) {
        self.customCastClient = castClient
        self.castClient = castClient
        #if canImport(Network)
        self.transportFactory = transportFactory ?? { _ in NWConnectionCastTransport() }
        #else
        self.transportFactory = transportFactory
        #endif
        self.httpPoster = httpPoster
        self.connectTimeout = connectTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
    }

    public init(
        castClient: CastV2Client? = nil,
        transportFactory: (@Sendable (DiscoveredDevice) -> CastTransport)? = nil,
        httpPoster: (@Sendable (URL) async throws -> Void)?
    ) {
        if let poster = httpPoster {
            self.init(
                castClient: castClient,
                transportFactory: transportFactory,
                httpPoster: { @Sendable (url: URL, _: Data?) async throws in
                    try await poster(url)
                }
            )
        } else {
            self.init(
                castClient: castClient,
                transportFactory: transportFactory,
                httpPoster: Optional<HTTPPoster>.none
            )
        }
    }

    // MARK: - State Notification

    public func setOnConnectionStateChanged(_ handler: (@Sendable (CastConnectionState) -> Void)?) {
        self.onConnectionStateChanged = handler
    }

    public func setOnPhaseChanged(_ handler: (@Sendable (CastPhase) -> Void)?) {
        self.onPhaseChanged = handler
    }

    /// The single place phase (and therefore `connectionState`) changes.
    private func transition(_ newPhase: CastPhase, ready: Bool? = nil) {
        let oldPhase = phase
        let oldState = connectionState
        if let ready = ready { receiverReady = ready }
        phase = newPhase
        if case .failed(let failure) = newPhase {
            errorMessage = failure.message
        }
        if newPhase != oldPhase {
            onPhaseChanged?(newPhase)
        }
        let newState = connectionState
        if newState != oldState {
            onConnectionStateChanged?(newState)
        }
    }

    @discardableResult
    private func fail(_ failure: CastFailure) -> CastFailure {
        isPlaying = false
        transition(.failed(failure))
        return failure
    }

    private func failure(from error: Error) -> CastFailure {
        if let failure = error as? CastFailure { return failure }
        if let transportError = error as? CastTransportError {
            switch transportError {
            case .waiting(let reason): return .localNetworkPermission(reason)
            case .connectionFailed(let reason), .sendFailed(let reason): return .connectionFailed(reason)
            default: return .connectionFailed("\(transportError)")
            }
        }
        if let v2 = error as? CastV2Error {
            switch v2 {
            case .launchFailed(let reason): return .launchFailed(reason)
            case .applicationNotFound(let id): return .launchFailed("application \(id) not found")
            case .timeout: return .connectionFailed("the TV did not respond")
            default: return .connectionFailed("\(v2)")
            }
        }
        return .connectionFailed(error.localizedDescription)
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
        self.currentMediaTitle = nil
        transition(.idle, ready: false)
    }

    // MARK: - Connection & Preparation

    public func connect(to device: DiscoveredDevice) async throws {
        self.selectedDevice = device
        self.errorMessage = nil

        switch device.type {
        case .chromecast:
            do {
                _ = try await establishSession(with: device)
                transition(.idle, ready: true)
            } catch {
                throw fail(failure(from: error))
            }

        case .roku, .dlna, .web:
            transition(.idle, ready: true)
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
        mirrorStream: MirrorStream,
        networkHelper: NetworkInterfaceHelper = .shared,
        port: Int? = nil
    ) async throws -> String {
        self.activeMirrorStream = mirrorStream
        let boundPort = try await mirrorStream.start()
        let portToUse = UInt16(port ?? Int(boundPort))
        let resolvedURL: String
        do {
            (resolvedURL, _) = try networkHelper.resolveStreamURL(port: portToUse, path: "stream.m3u8")
        } catch {
            await mirrorStream.stop()
            self.activeMirrorStream = nil
            fail(.networkUnavailable(error.localizedDescription))
            throw error
        }
        self.currentMediaURL = resolvedURL

        if let device = selectedDevice {
            try await castMedia(url: resolvedURL, to: device, title: "Screen Mirror")
        }

        return resolvedURL
    }

    public func stopScreenMirror(mirrorStream: MirrorStream) async throws {
        try? await self.stop(disconnect: false)
        await mirrorStream.stop()
        self.activeMirrorStream = nil
        if let client = self.castClient, await client.isConnected {
            transition(.idle, ready: true)
        } else if selectedDevice != nil && selectedDevice?.type != .chromecast {
            transition(.idle, ready: true)
        } else {
            transition(.idle, ready: false)
        }
    }

    // MARK: - Media Casting & Playback

    public func castMedia(url: String, to device: DiscoveredDevice, title: String? = nil) async throws {
        self.selectedDevice = device
        self.currentMediaURL = url
        self.currentMediaTitle = title
        self.currentPositionSeconds = 0

        switch device.type {
        case .roku:
            self.isPlaying = true
            let launchURL = RokuECPClient.buildLaunchURL(deviceIP: device.ipAddress, mediaURL: url)
            try? await sendHTTPPost(url: launchURL)
            transition(.playing, ready: true)

        case .dlna:
            self.isPlaying = true
            let soap = UPnPClient.generateSetAVTransportURIPayload(mediaURL: url)
            await sendSOAP(action: "SetAVTransportURI", payload: soap, on: device)
            try? await play()
            transition(.playing, ready: true)

        case .chromecast:
            do {
                try await castChromecastV2(url: url, to: device, title: title)
            } catch {
                throw fail(failure(from: error))
            }

        case .web:
            self.isPlaying = true
            transition(.playing, ready: true)
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

    public func stop(disconnect: Bool = true) async throws {
        guard let device = selectedDevice else {
            transition(.idle, ready: false)
            return
        }
        self.isPlaying = false
        self.currentMediaURL = nil
        self.currentMediaTitle = nil

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
                if disconnect {
                    await client.disconnect()
                }
            }
            if disconnect {
                if self.customCastClient == nil {
                    self.castClient = nil
                }
                self.activeTransportId = nil
            }
            self.mediaSessionId = nil

        case .web:
            break
        }

        if let client = self.castClient, await client.isConnected {
            transition(.idle, ready: true)
        } else if !disconnect && selectedDevice != nil && selectedDevice?.type != .chromecast {
            transition(.idle, ready: true)
        } else {
            transition(.idle, ready: false)
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
        switch phase {
        case .idle where receiverReady:
            if self.customCastClient == nil {
                self.castClient = nil
            }
            self.activeTransportId = nil
            self.mediaSessionId = nil
            transition(.idle, ready: false)
            return
        case .buffering, .playing:
            break
        default:
            return
        }
        guard !isReconnecting else { return }

        isReconnecting = true
        defer { isReconnecting = false }
        transition(.connecting)

        guard let device = selectedDevice, let mediaURL = currentMediaURL else {
            await handleReconnectionFailure()
            return
        }

        let titleToRestore = self.currentMediaTitle
        for attempt in 1...max(1, maxReconnectAttempts) {
            if let client = self.castClient {
                await client.disconnect()
                if self.customCastClient == nil {
                    self.castClient = nil
                }
            }
            self.activeTransportId = nil
            self.mediaSessionId = nil

            if reconnectDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * Double(attempt) * 1_000_000_000))
            }

            do {
                try await castChromecastV2(url: mediaURL, to: device, title: titleToRestore)
                self.errorMessage = nil
                return
            } catch {
                transition(.connecting)
            }
        }
        await handleReconnectionFailure()
    }

    private func handleReconnectionFailure() async {
        self.isPlaying = false
        self.currentMediaURL = nil
        self.currentMediaTitle = nil
        self.mediaSessionId = nil
        self.activeTransportId = nil

        if let controller = self.activeMirrorStream {
            await controller.stop()
            self.activeMirrorStream = nil
        }

        fail(.reconnectFailed)
    }

    // MARK: - Receiver-initiated messages

    private func handleReceiverMessage(_ message: CastMessage, _ json: [String: Any]) async {
        guard let type = json["type"] as? String else { return }

        if message.namespace == CastNamespaces.connection, type == "CLOSE" {
            await endSessionFromReceiver()
            return
        }

        guard message.namespace == CastNamespaces.media, type == "MEDIA_STATUS" else { return }
        switch phase {
        case .loading, .buffering, .playing:
            break
        default:
            return
        }
        guard let status = (json["status"] as? [[String: Any]])?.first,
              let playerState = status["playerState"] as? String else { return }

        switch playerState {
        case "PLAYING":
            isPlaying = true
            transition(.playing)
        case "BUFFERING":
            transition(.buffering)
        case "PAUSED":
            isPlaying = false
        case "IDLE":
            switch status["idleReason"] as? String {
            case "ERROR":
                fail(.receiverError("ERROR"))
            case "FINISHED":
                isPlaying = false
                transition(.ended("finished"))
            case "CANCELLED":
                isPlaying = false
                transition(.ended("cancelled"))
            default:
                break
            }
        default:
            break
        }
    }

    private func endSessionFromReceiver() async {
        switch phase {
        case .ended, .failed:
            return
        default:
            break
        }
        isPlaying = false
        mediaSessionId = nil
        activeTransportId = nil
        if let client = castClient {
            await client.disconnect()
            if customCastClient == nil { castClient = nil }
        }
        transition(.ended(Self.stoppedOnTV), ready: false)
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
            self.activeTransport = transport
            client = CastV2Client(transport: transport)
            self.castClient = client
        } else {
            throw CastTransportError.connectionFailed("No CastTransport factory available for Chromecast")
        }

        await client.setOnDisconnect { [weak self] in
            await self?.handleUnexpectedDisconnection()
        }
        await client.setOnUnsolicitedMessage { [weak self] message, json in
            await self?.handleReceiverMessage(message, json)
        }
        return client
    }

    /// Connects (if needed) and launches the Default Media Receiver (if needed), all under the connect timeout.
    private func establishSession(with device: DiscoveredDevice) async throws -> String {
        let client = try await getOrCreateCastClient(for: device)
        let transportId = try await withConnectTimeout { [self] in
            if await !client.isConnected {
                await self.transition(.connecting)
                let port = device.port == 0 ? CastConstants.defaultPort : device.port
                try await client.connect(host: device.ipAddress, port: port)
            }
            if let existing = await client.activeTransportId {
                return existing
            }
            await self.transition(.launching)
            return try await client.launchReceiver(appId: CastConstants.defaultAppId).transportId
        }
        self.activeTransportId = transportId
        return transportId
    }

    private func castChromecastV2(url: String, to device: DiscoveredDevice, title: String?) async throws {
        let transportId = try await establishSession(with: device)
        guard let client = self.castClient else { throw CastFailure.connectionFailed("no Cast client") }
        transition(.loading, ready: true)

        let isHLS = url.lowercased().contains(".m3u8")

        let resolvedTitle: String
        if let title = title, !title.isEmpty {
            resolvedTitle = title
        } else if let parsed = URL(string: url), !parsed.lastPathComponent.isEmpty, parsed.lastPathComponent != "/" {
            resolvedTitle = parsed.lastPathComponent
        } else {
            resolvedTitle = "Cast Stream"
        }

        var media: [String: Any] = [
            "contentId": url,
            "streamType": isHLS ? "LIVE" : "BUFFERED",
            "contentType": isHLS ? "application/x-mpegURL" : "video/mp4",
            "metadata": [
                "title": resolvedTitle,
                "metadataType": 0
            ]
        ]
        if isHLS {
            media["hlsVideoSegmentFormat"] = "mpeg2_ts"
        }

        let loadPayload: [String: Any] = [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": 0,
            "media": media
        ]

        let response = try await client.request(
            namespace: CastNamespaces.media,
            destinationId: transportId,
            payload: loadPayload
        )

        let loadedPhase = try interpretLoadResponse(response)

        self.selectedDevice = device
        self.currentMediaURL = url
        self.currentMediaTitle = title
        self.isPlaying = true
        self.currentPositionSeconds = 0
        transition(loadedPhase)
    }

    /// Maps the receiver's reply to LOAD onto the next phase, or throws the receiver's reason.
    private func interpretLoadResponse(_ response: [String: Any]) throws -> CastPhase {
        let type = response["type"] as? String
        if type == "LOAD_FAILED" || type == "INVALID_REQUEST" {
            let reason = (response["reason"] as? String)
                ?? (response["detailedErrorCode"] as? Int).map { "error code \($0)" }
                ?? type ?? "LOAD_FAILED"
            throw CastFailure.loadFailed(reason)
        }

        let status = (response["status"] as? [[String: Any]])?.first
        if status?["playerState"] as? String == "IDLE", let idle = status?["idleReason"] as? String, idle == "ERROR" {
            throw CastFailure.receiverError(idle)
        }

        guard let sessionId = extractMediaSessionId(from: response) else {
            throw CastFailure.loadFailed("missing mediaSessionId in receiver response")
        }
        self.mediaSessionId = sessionId
        return status?["playerState"] as? String == "BUFFERING" ? .buffering : .playing
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

    // MARK: - Connect timeout

    private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var timer: Task<Void, Never>?
        private let continuation: CheckedContinuation<T, Error>

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func setTimer(_ task: Task<Void, Never>) {
            lock.lock()
            timer = task
            let alreadyDone = done
            lock.unlock()
            if alreadyDone { task.cancel() }
        }

        /// Returns true if this call decided the race.
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            guard !done else {
                lock.unlock()
                return false
            }
            done = true
            let timer = self.timer
            lock.unlock()
            timer?.cancel()
            continuation.resume(with: result)
            return true
        }
    }

    private func withConnectTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = connectTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let race = TimeoutRace<T>(continuation)
            let work = Task {
                do {
                    _ = race.finish(.success(try await operation()))
                } catch {
                    _ = race.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if race.finish(.failure(CastFailure.connectTimeout)) {
                    work.cancel()
                    await self.abortPendingConnection()
                }
            }
            race.setTimer(timer)
        }
    }

    /// Closing the transport unblocks a connect that is stuck (e.g. NWConnection retrying in `.waiting`).
    private func abortPendingConnection() async {
        await activeTransport?.close()
        if customCastClient == nil {
            castClient = nil
        }
    }

    // MARK: - Networking (Roku / DLNA)

    private func sendSOAP(action: String, payload: String, on device: DiscoveredDevice) async {
        guard let controlURL = device.controlURL else { return }
        if let poster = self.httpPoster {
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
        if let poster = self.httpPoster {
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
