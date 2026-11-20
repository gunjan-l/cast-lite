import Foundation

public enum CastTransportError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case sendFailed(String)
    case cancelled
    /// The transport cannot proceed (NWConnection `.waiting`), e.g. Local Network permission denied.
    case waiting(String)
}

public protocol CastTransport: Sendable {
    var isConnected: Bool { get async }
    func connect(host: String, port: UInt16) async throws
    func send(data: Data) async throws
    func receiveStream() -> AsyncThrowingStream<Data, Error>
    func close() async
}

