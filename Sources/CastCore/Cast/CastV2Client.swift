import Foundation

public enum CastNamespaces {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}

public enum CastConstants {
    public static let defaultReceiverId = "receiver-0"
    public static let defaultSenderId = "sender-0"
    public static let defaultAppId = "CC1AD845"
    public static let defaultPort: UInt16 = 8009
    public static let defaultHeartbeatInterval: TimeInterval = 5.0
    public static let defaultRequestTimeout: TimeInterval = 7.0
}

public enum CastV2Error: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case timeout(Int)
    case disconnected
    case applicationNotFound(String)
    case launchFailed(String)
    case invalidResponse(String)
}

public actor CastV2Client {
    private let transport: CastTransport
    public let clientSourceId: String
    public let heartbeatInterval: TimeInterval
    public let requestTimeout: TimeInterval

    public private(set) var isConnected: Bool = false
    public private(set) var activeSessionId: String?
    public private(set) var activeTransportId: String?

    private var currentRequestId: Int = 0
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    public private(set) var onDisconnect: (@Sendable () async -> Void)?

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pendingRequests: [Int: PendingRequest] = [:]

    public init(
        transport: CastTransport,
        clientSourceId: String = CastConstants.defaultSenderId,
        heartbeatInterval: TimeInterval = CastConstants.defaultHeartbeatInterval,
        requestTimeout: TimeInterval = CastConstants.defaultRequestTimeout
    ) {
        self.transport = transport
        self.clientSourceId = clientSourceId
        self.heartbeatInterval = heartbeatInterval
        self.requestTimeout = requestTimeout
    }

    public func setOnDisconnect(_ handler: (@Sendable () async -> Void)?) {
        self.onDisconnect = handler
    }

    // MARK: - Lifecycle

    public func connect(host: String = "127.0.0.1", port: UInt16 = CastConstants.defaultPort) async throws {
        guard !isConnected else {
            throw CastV2Error.alreadyConnected
        }

        if await !transport.isConnected {
            try await transport.connect(host: host, port: port)
        }

        isConnected = true
        startReceiveLoop()

        let connectMessage = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: clientSourceId,
            destinationId: CastConstants.defaultReceiverId,
            namespace: CastNamespaces.connection,
            payloadType: .string,
            payloadUtf8: "{\"type\":\"CONNECT\"}"
        )

        do {
            try await sendCastMessage(connectMessage)
        } catch {
            cleanupLocalState()
            await transport.close()
            throw error
        }

        startHeartbeatLoop()
    }

    public func disconnect() async {
        let transportIsConnected = await transport.isConnected
        guard isConnected || transportIsConnected else {
            cleanupLocalState()
            return
        }

        let savedHandler = onDisconnect
        onDisconnect = nil
        defer { onDisconnect = savedHandler }

        heartbeatTask?.cancel()
        heartbeatTask = nil

        if let transportId = activeTransportId {
            let closeApp = CastMessage(
                protocolVersion: .castv2_1_0,
                sourceId: clientSourceId,
                destinationId: transportId,
                namespace: CastNamespaces.connection,
                payloadType: .string,
                payloadUtf8: "{\"type\":\"CLOSE\"}"
            )
            try? await sendCastMessage(closeApp)
        }

        let closeReceiver = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: clientSourceId,
            destinationId: CastConstants.defaultReceiverId,
            namespace: CastNamespaces.connection,
            payloadType: .string,
            payloadUtf8: "{\"type\":\"CLOSE\"}"
        )
        try? await sendCastMessage(closeReceiver)

        cleanupLocalState()
        await transport.close()
    }

    // MARK: - Receiver Launch

    public func launchReceiver(appId: String = CastConstants.defaultAppId) async throws -> (sessionId: String, transportId: String) {
        guard isConnected else {
            throw CastV2Error.notConnected
        }

        let response = try await request(
            namespace: CastNamespaces.receiver,
            destinationId: CastConstants.defaultReceiverId,
            payload: [
                "type": "LAUNCH",
                "appId": appId
            ]
        )

        if let type = response["type"] as? String, type == "LAUNCH_ERROR" {
            let reason = response["reason"] as? String ?? "Receiver launch failed"
            throw CastV2Error.launchFailed(reason)
        }

        guard let status = response["status"] as? [String: Any],
              let applications = status["applications"] as? [[String: Any]] else {
            throw CastV2Error.invalidResponse("Missing status.applications in receiver response")
        }

        guard let app = applications.first(where: { ($0["appId"] as? String) == appId }) else {
            throw CastV2Error.applicationNotFound(appId)
        }

        guard let sessionId = app["sessionId"] as? String,
              let transportId = app["transportId"] as? String else {
            throw CastV2Error.invalidResponse("Missing sessionId or transportId in application status")
        }

        let appConnect = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: clientSourceId,
            destinationId: transportId,
            namespace: CastNamespaces.connection,
            payloadType: .string,
            payloadUtf8: "{\"type\":\"CONNECT\"}"
        )
        try await sendCastMessage(appConnect)

        self.activeSessionId = sessionId
        self.activeTransportId = transportId

        return (sessionId: sessionId, transportId: transportId)
    }

    // MARK: - Messaging & Request Correlation

    public func send(message: CastMessage) async throws {
        guard isConnected else {
            throw CastV2Error.notConnected
        }
        try await sendCastMessage(message)
    }

    public func nextRequestId() -> Int {
        currentRequestId += 1
        return currentRequestId
    }

    public func request(
        namespace: String,
        destinationId: String,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        guard isConnected else {
            throw CastV2Error.notConnected
        }

        let reqId = nextRequestId()
        var fullPayload = payload
        fullPayload["requestId"] = reqId

        let payloadData = try JSONSerialization.data(withJSONObject: fullPayload)
        guard let payloadUtf8 = String(data: payloadData, encoding: .utf8) else {
            throw CastCodecError.invalidUTF8String
        }

        let message = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: clientSourceId,
            destinationId: destinationId,
            namespace: namespace,
            payloadType: .string,
            payloadUtf8: payloadUtf8
        )

        return try await withCheckedThrowingContinuation { continuation in
            let timeout = self.requestTimeout
            let timeoutTask = Task { [weak self, reqId] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.handleRequestTimeout(requestId: reqId)
            }

            self.pendingRequests[reqId] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.sendCastMessage(message)
                } catch {
                    await self.handleRequestSendFailed(requestId: reqId, error: error)
                }
            }
        }
    }

    // MARK: - Internal Transport Helpers

    private func sendCastMessage(_ message: CastMessage) async throws {
        let framed = try CastPacketFramer.frame(message: message)
        try await transport.send(data: framed)
    }

    private func handleRequestTimeout(requestId: Int) {
        if let pending = pendingRequests.removeValue(forKey: requestId) {
            pending.continuation.resume(throwing: CastV2Error.timeout(requestId))
        }
    }

    private func handleRequestSendFailed(requestId: Int, error: Error) {
        if let pending = pendingRequests.removeValue(forKey: requestId) {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    // MARK: - Heartbeat Loop

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self = self else { break }
                let stillConnected = await self.isConnected
                guard stillConnected else { break }
                await self.sendPing()
            }
        }
    }

    private func sendPing() async {
        let ping = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: clientSourceId,
            destinationId: CastConstants.defaultReceiverId,
            namespace: CastNamespaces.heartbeat,
            payloadType: .string,
            payloadUtf8: "{\"type\":\"PING\"}"
        )
        try? await sendCastMessage(ping)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        let stream = transport.receiveStream()
        receiveTask = Task { [weak self] in
            var framer = CastPacketFramer()
            do {
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    let packets = try framer.append(chunk)
                    for packet in packets {
                        guard !Task.isCancelled else { break }
                        let message = try CastMessageCodec.decode(packet)
                        await self?.handleIncomingMessage(message)
                    }
                }
            } catch {
                await self?.handleReceiveError(error)
            }
            await self?.handleStreamEnded()
        }
    }

    private func handleIncomingMessage(_ message: CastMessage) async {
        if message.namespace == CastNamespaces.heartbeat {
            if let payload = message.payloadUtf8, payload.contains("PING") {
                let pongDestination = message.sourceId.isEmpty ? CastConstants.defaultReceiverId : message.sourceId
                let pong = CastMessage(
                    protocolVersion: .castv2_1_0,
                    sourceId: clientSourceId,
                    destinationId: pongDestination,
                    namespace: CastNamespaces.heartbeat,
                    payloadType: .string,
                    payloadUtf8: "{\"type\":\"PONG\"}"
                )
                try? await sendCastMessage(pong)
            }
        }

        if let payload = message.payloadUtf8,
           let data = payload.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var reqId: Int?
            if let id = json["requestId"] as? Int {
                reqId = id
            } else if let num = json["requestId"] as? NSNumber {
                reqId = num.intValue
            }

            if let reqId = reqId, let pending = pendingRequests.removeValue(forKey: reqId) {
                pending.timeoutTask.cancel()
                pending.continuation.resume(returning: json)
            }
        }
    }

    private func cleanupLocalState() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        for (_, pending) in pendingRequests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: CastV2Error.disconnected)
        }
        pendingRequests.removeAll()

        isConnected = false
        activeSessionId = nil
        activeTransportId = nil
    }

    private func handleReceiveError(_ error: Error) async {
        let wasConnected = isConnected
        cleanupLocalState()
        await transport.close()
        if wasConnected {
            await onDisconnect?()
        }
    }

    private func handleStreamEnded() async {
        if isConnected {
            cleanupLocalState()
            await transport.close()
            await onDisconnect?()
        }
    }
}
