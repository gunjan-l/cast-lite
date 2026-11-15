import Foundation

#if canImport(Network)
import Network
import Security

public final class NWConnectionCastTransport: CastTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.castlite.cast.transport")
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var activeStream: AsyncThrowingStream<Data, Error>?
    private var _isConnected: Bool = false
    private var _isReceiving: Bool = false

    public init() {}

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    public func connect(host: String, port: UInt16) async throws {
        lock.lock()
        if _isConnected || connection != nil {
            lock.unlock()
            throw CastTransportError.alreadyConnected
        }
        lock.unlock()

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { (_, _, completionHandler) in
                // Bypass self-signed device certificate verification on port 8009
                completionHandler(true)
            },
            queue
        )

        let parameters = NWParameters(tls: tlsOptions)
        parameters.includePeerToPeer = true

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CastTransportError.connectionFailed("Invalid port: \(port)")
        }

        let nwConnection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)

        lock.lock()
        if activeStream == nil {
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                self.streamContinuation = continuation
            }
            self.activeStream = stream
        }
        self.connection = nwConnection
        lock.unlock()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeLock = NSLock()
            var resumed = false

            nwConnection.stateUpdateHandler = { [weak self, weak nwConnection] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    self._isConnected = true
                    let shouldStartLoop = !self._isReceiving
                    if shouldStartLoop {
                        self._isReceiving = true
                    }
                    self.lock.unlock()

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                    resumeLock.unlock()

                    if shouldStartLoop {
                        self.startReceiveLoop(nwConnection)
                    }

                case .failed(let error):
                    self.lock.lock()
                    self._isConnected = false
                    self._isReceiving = false
                    self.connection = nil
                    let cont = self.streamContinuation
                    self.streamContinuation = nil
                    self.activeStream = nil
                    self.lock.unlock()
                    cont?.finish(throwing: error)

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: CastTransportError.connectionFailed(error.localizedDescription))
                    }
                    resumeLock.unlock()

                case .cancelled:
                    self.lock.lock()
                    self._isConnected = false
                    self._isReceiving = false
                    self.connection = nil
                    let cont = self.streamContinuation
                    self.streamContinuation = nil
                    self.activeStream = nil
                    self.lock.unlock()
                    cont?.finish()

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: CastTransportError.cancelled)
                    }
                    resumeLock.unlock()

                default:
                    break
                }
            }

            nwConnection.start(queue: queue)
        }
    }

    private func startReceiveLoop(_ conn: NWConnection?) {
        guard let conn = conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self else { return }

            if let content = content, !content.isEmpty {
                self.lock.lock()
                let cont = self.streamContinuation
                self.lock.unlock()
                cont?.yield(content)
            }

            if let error = error {
                self.lock.lock()
                self._isConnected = false
                self._isReceiving = false
                self.connection = nil
                let cont = self.streamContinuation
                self.streamContinuation = nil
                self.activeStream = nil
                self.lock.unlock()
                cont?.finish(throwing: error)
                return
            }

            if isComplete {
                self.lock.lock()
                self._isConnected = false
                self._isReceiving = false
                self.connection = nil
                let cont = self.streamContinuation
                self.streamContinuation = nil
                self.activeStream = nil
                self.lock.unlock()
                cont?.finish()
                return
            }

            if self.isConnected {
                self.startReceiveLoop(conn)
            }
        }
    }

    public func send(data: Data) async throws {
        lock.lock()
        guard _isConnected, let conn = connection else {
            lock.unlock()
            throw CastTransportError.notConnected
        }
        lock.unlock()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: CastTransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
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

    public func close() async {
        lock.lock()
        _isConnected = false
        _isReceiving = false
        let conn = connection
        connection = nil
        let cont = streamContinuation
        streamContinuation = nil
        activeStream = nil
        lock.unlock()

        conn?.cancel()
        cont?.finish()
    }
}
#endif
