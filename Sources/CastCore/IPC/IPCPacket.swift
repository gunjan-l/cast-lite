import Foundation

public enum IPCPacketType: UInt8, Sendable, Equatable {
    case video = 0x01
    case audio = 0x02
    case heartbeat = 0x03
}

public struct IPCPacket: Sendable, Equatable {
    public static let magic: UInt32 = 0x43415354 // "CAST"

    public let type: IPCPacketType
    public let isKeyframe: Bool
    public let timestamp: UInt64
    public let payload: Data

    public init(type: IPCPacketType, isKeyframe: Bool = false, timestamp: UInt64, payload: Data = Data()) {
        self.type = type
        self.isKeyframe = isKeyframe
        self.timestamp = timestamp
        self.payload = payload
    }

    public func serialize() -> Data {
        var data = Data()
        var magicBE = Self.magic.bigEndian
        data.append(Data(bytes: &magicBE, count: 4))

        var rawType = type.rawValue
        data.append(Data(bytes: &rawType, count: 1))

        var flags: UInt8 = isKeyframe ? 0x01 : 0x00
        data.append(Data(bytes: &flags, count: 1))

        var timestampBE = timestamp.bigEndian
        data.append(Data(bytes: &timestampBE, count: 8))

        var lengthBE = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &lengthBE, count: 4))

        data.append(payload)
        return data
    }

    public static func deserialize(from data: Data) -> IPCPacket? {
        guard data.count >= 18 else { return nil }

        let magicValue: UInt32 = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        }
        guard magicValue == Self.magic else { return nil }

        let rawType = data[4]
        guard let type = IPCPacketType(rawValue: rawType) else { return nil }

        let flags = data[5]
        let isKeyframe = (flags & 0x01) != 0

        let timestamp: UInt64 = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 6, as: UInt64.self).bigEndian
        }

        let payloadLength: UInt32 = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 14, as: UInt32.self).bigEndian
        }

        let totalExpectedLength = 18 + Int(payloadLength)
        guard data.count >= totalExpectedLength else { return nil }

        let payload = data.subdata(in: 18..<totalExpectedLength)
        return IPCPacket(type: type, isKeyframe: isKeyframe, timestamp: timestamp, payload: payload)
    }
}
