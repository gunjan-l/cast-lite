import Foundation

public struct CastMessage: Equatable, Sendable {
    public enum ProtocolVersion: Int, Equatable, Sendable {
        case castv2_1_0 = 0
    }

    public enum PayloadType: Int, Equatable, Sendable {
        case string = 0
        case binary = 1
    }

    public var protocolVersion: ProtocolVersion
    public var sourceId: String
    public var destinationId: String
    public var namespace: String
    public var payloadType: PayloadType
    public var payloadUtf8: String?
    public var payloadBinary: Data?

    public init(
        protocolVersion: ProtocolVersion = .castv2_1_0,
        sourceId: String,
        destinationId: String,
        namespace: String,
        payloadType: PayloadType = .string,
        payloadUtf8: String? = nil,
        payloadBinary: Data? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.namespace = namespace
        self.payloadType = payloadType
        self.payloadUtf8 = payloadUtf8
        self.payloadBinary = payloadBinary
    }
}
