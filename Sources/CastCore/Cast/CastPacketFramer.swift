import Foundation

public enum CastFramerError: Error, Equatable, Sendable {
    case packetExceedsMaximumSize(UInt32)
}

public struct CastPacketFramer: Sendable {
    public static let defaultMaxPacketLength: UInt32 = 512 * 1024 // 512 KB

    public let maxPacketLength: UInt32
    private var buffer = Data()

    public init(maxPacketLength: UInt32 = CastPacketFramer.defaultMaxPacketLength) {
        self.maxPacketLength = maxPacketLength
    }

    public var isEmpty: Bool {
        buffer.isEmpty
    }

    public var bufferedBytesCount: Int {
        buffer.count
    }

    public mutating func reset() {
        buffer.removeAll()
    }

    public static func frame(payload: Data) -> Data {
        var framed = Data(capacity: 4 + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { ptr in
            framed.append(contentsOf: ptr)
        }
        framed.append(payload)
        return framed
    }

    public static func frame(message: CastMessage) throws -> Data {
        let payload = try CastMessageCodec.encode(message)
        return frame(payload: payload)
    }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var packets: [Data] = []

        while buffer.count >= 4 {
            let start = buffer.startIndex
            let b0 = UInt32(buffer[start])
            let b1 = UInt32(buffer[buffer.index(start, offsetBy: 1)])
            let b2 = UInt32(buffer[buffer.index(start, offsetBy: 2)])
            let b3 = UInt32(buffer[buffer.index(start, offsetBy: 3)])
            let length = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            guard length <= maxPacketLength else {
                buffer.removeAll()
                throw CastFramerError.packetExceedsMaximumSize(length)
            }

            let totalLength = 4 + Int(length)
            if buffer.count >= totalLength {
                let payloadStart = buffer.index(start, offsetBy: 4)
                let payloadEnd = buffer.index(start, offsetBy: totalLength)
                let payload = buffer.subdata(in: payloadStart..<payloadEnd)
                packets.append(payload)
                buffer.removeSubrange(start..<payloadEnd)
            } else {
                break
            }
        }

        return packets
    }
}
