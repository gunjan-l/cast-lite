import Foundation

public final class MockCastTransport: CastTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _isConnected: Bool = false
    private var _connectedHost: String?
    private var _connectedPort: UInt16?
    private var _sentPackets: [Data] = []
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var activeStream: AsyncThrowingStream<Data, Error>?
    private var _shouldFailConnection: Error?
    private var _hangConnection: Bool = false
    private var _onSend: (@Sendable (Data) async throws -> Void)?

    public var shouldFailConnection: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldFailConnection
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shouldFailConnection = newValue
        }
    }

    public var onSend: (@Sendable (Data) async throws -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onSend
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onSend = newValue
        }
    }

    public var hangConnection: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hangConnection }
        set { lock.lock(); defer { lock.unlock() }; _hangConnection = newValue }
    }

    public init() {}

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    public var connectedHost: String? {
        lock.lock()
        defer { lock.unlock() }
        return _connectedHost
    }

    public var connectedPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return _connectedPort
    }

    public var sentPackets: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _sentPackets
    }

    public func clearSent() {
        lock.lock()
        defer { lock.unlock() }
        _sentPackets.removeAll()
    }

    public func connect(host: String, port: UInt16) async throws {
        lock.lock()
        if _isConnected {
            lock.unlock()
            throw CastTransportError.alreadyConnected
        }
        if let failError = _shouldFailConnection {
            lock.unlock()
            throw failError
        }
        if _hangConnection {
            lock.unlock()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { throw CastTransportError.cancelled }
            throw CastTransportError.cancelled
        }
        _isConnected = true
        _connectedHost = host
        _connectedPort = port

        if activeStream == nil {
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                self.streamContinuation = continuation
            }
            self.activeStream = stream
        }
        lock.unlock()
    }

    public func send(data: Data) async throws {
        lock.lock()
        guard _isConnected else {
            lock.unlock()
            throw CastTransportError.notConnected
        }
        _sentPackets.append(data)
        let handler = _onSend
        lock.unlock()

        if let handler = handler {
            try await handler(data)
        }
    }

    public func receiveStream() -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let stream = activeStream {
            return stream
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.streamContinuation = continuation
        }
        self.activeStream = stream
        return stream
    }

    public func simulateReceive(data: Data) {
        lock.lock()
        let continuation = streamContinuation
        lock.unlock()
        continuation?.yield(data)
    }

    public func finishReceiveStream() {
        lock.lock()
        let continuation = streamContinuation
        streamContinuation = nil
        activeStream = nil
        lock.unlock()
        continuation?.finish()
    }

    public func simulateError(_ error: Error) {
        lock.lock()
        let continuation = streamContinuation
        streamContinuation = nil
        activeStream = nil
        _isConnected = false
        lock.unlock()
        continuation?.finish(throwing: error)
    }

    public func simulateDisconnect() {
        lock.lock()
        _isConnected = false
        lock.unlock()
        finishReceiveStream()
    }

    public func close() async {
        simulateDisconnect()
    }
}

