import Foundation

public enum CastCodecError: Error, Equatable, Sendable {
    case unexpectedEndOfData
    case malformedVarint
    case missingRequiredField(String)
    case invalidUTF8String
    case unsupportedWireType(Int)
}

public enum CastMessageCodec {

    // MARK: - Encode

    public static func encode(_ message: CastMessage) throws -> Data {
        var data = Data()

        // Field 1: protocol_version (enum -> varint, tag = 0x08)
        writeVarintField(field: 1, value: UInt64(message.protocolVersion.rawValue), into: &data)

        // Field 2: source_id (string, tag = 0x12)
        writeString(field: 2, string: message.sourceId, into: &data)

        // Field 3: destination_id (string, tag = 0x1A)
        writeString(field: 3, string: message.destinationId, into: &data)

        // Field 4: namespace (string, tag = 0x22)
        writeString(field: 4, string: message.namespace, into: &data)

        // Field 5: payload_type (enum -> varint, tag = 0x28)
        writeVarintField(field: 5, value: UInt64(message.payloadType.rawValue), into: &data)

        // Field 6: payload_utf8 (optional string, tag = 0x32)
        if let utf8 = message.payloadUtf8 {
            writeString(field: 6, string: utf8, into: &data)
        }

        // Field 7: payload_binary (optional bytes, tag = 0x3A)
        if let binary = message.payloadBinary {
            writeBytes(field: 7, bytes: binary, into: &data)
        }

        return data
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> CastMessage {
        var reader = Reader(data: data)

        var protocolVersion: CastMessage.ProtocolVersion?
        var sourceId: String?
        var destinationId: String?
        var namespace: String?
        var payloadType: CastMessage.PayloadType?
        var payloadUtf8: String?
        var payloadBinary: Data?

        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let wireType = Int(tag & 0x07)
            let fieldNumber = Int(tag >> 3)

            switch fieldNumber {
            case 1:
                guard wireType == 0 else { throw CastCodecError.unsupportedWireType(wireType) }
                let val = try reader.readVarint()
                protocolVersion = CastMessage.ProtocolVersion(rawValue: Int(val)) ?? .castv2_1_0
            case 2:
                guard wireType == 2 else { throw CastCodecError.unsupportedWireType(wireType) }
                let bytes = try reader.readLengthPrefixedBytes()
                guard let str = String(data: bytes, encoding: .utf8) else {
                    throw CastCodecError.invalidUTF8String
                }
                sourceId = str
            case 3:
                guard wireType == 2 else { throw CastCodecError.unsupportedWireType(wireType) }
                let bytes = try reader.readLengthPrefixedBytes()
                guard let str = String(data: bytes, encoding: .utf8) else {
                    throw CastCodecError.invalidUTF8String
                }
                destinationId = str
            case 4:
                guard wireType == 2 else { throw CastCodecError.unsupportedWireType(wireType) }
                let bytes = try reader.readLengthPrefixedBytes()
                guard let str = String(data: bytes, encoding: .utf8) else {
                    throw CastCodecError.invalidUTF8String
                }
                namespace = str
            case 5:
                guard wireType == 0 else { throw CastCodecError.unsupportedWireType(wireType) }
                let val = try reader.readVarint()
                payloadType = CastMessage.PayloadType(rawValue: Int(val)) ?? .string
            case 6:
                guard wireType == 2 else { throw CastCodecError.unsupportedWireType(wireType) }
                let bytes = try reader.readLengthPrefixedBytes()
                guard let str = String(data: bytes, encoding: .utf8) else {
                    throw CastCodecError.invalidUTF8String
                }
                payloadUtf8 = str
            case 7:
                guard wireType == 2 else { throw CastCodecError.unsupportedWireType(wireType) }
                payloadBinary = try reader.readLengthPrefixedBytes()
            default:
                try reader.skip(wireType: wireType)
            }
        }

        guard let protocolVersion = protocolVersion else {
            throw CastCodecError.missingRequiredField("protocol_version")
        }
        guard let sourceId = sourceId else {
            throw CastCodecError.missingRequiredField("source_id")
        }
        guard let destinationId = destinationId else {
            throw CastCodecError.missingRequiredField("destination_id")
        }
        guard let namespace = namespace else {
            throw CastCodecError.missingRequiredField("namespace")
        }
        guard let payloadType = payloadType else {
            throw CastCodecError.missingRequiredField("payload_type")
        }

        return CastMessage(
            protocolVersion: protocolVersion,
            sourceId: sourceId,
            destinationId: destinationId,
            namespace: namespace,
            payloadType: payloadType,
            payloadUtf8: payloadUtf8,
            payloadBinary: payloadBinary
        )
    }

    // MARK: - Internal Protobuf Helpers

    private static func writeVarint(_ value: UInt64, into data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
    }

    private static func writeTag(field: Int, wireType: Int, into data: inout Data) {
        writeVarint(UInt64((field << 3) | wireType), into: &data)
    }

    private static func writeString(field: Int, string: String, into data: inout Data) {
        let utf8 = Data(string.utf8)
        writeTag(field: field, wireType: 2, into: &data)
        writeVarint(UInt64(utf8.count), into: &data)
        data.append(utf8)
    }

    private static func writeBytes(field: Int, bytes: Data, into data: inout Data) {
        writeTag(field: field, wireType: 2, into: &data)
        writeVarint(UInt64(bytes.count), into: &data)
        data.append(bytes)
    }

    private static func writeVarintField(field: Int, value: UInt64, into data: inout Data) {
        writeTag(field: field, wireType: 0, into: &data)
        writeVarint(value, into: &data)
    }

    private struct Reader {
        let data: Data
        var offset: Int = 0

        var isAtEnd: Bool {
            offset >= data.count
        }

        mutating func readByte() throws -> UInt8 {
            guard offset < data.count else {
                throw CastCodecError.unexpectedEndOfData
            }
            let b = data[data.startIndex + offset]
            offset += 1
            return b
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let b = try readByte()
                result |= UInt64(b & 0x7F) << shift
                if (b & 0x80) == 0 {
                    return result
                }
                shift += 7
                if shift > 64 {
                    throw CastCodecError.malformedVarint
                }
            }
        }

        mutating func readBytes(count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else {
                throw CastCodecError.unexpectedEndOfData
            }
            let start = data.startIndex + offset
            let end = start + count
            offset += count
            return data.subdata(in: start..<end)
        }

        mutating func readLengthPrefixedBytes() throws -> Data {
            let len = try readVarint()
            guard len <= UInt64(Int.max) else {
                throw CastCodecError.unexpectedEndOfData
            }
            return try readBytes(count: Int(len))
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                _ = try readBytes(count: 8)
            case 2:
                _ = try readLengthPrefixedBytes()
            case 5:
                _ = try readBytes(count: 4)
            default:
                throw CastCodecError.unsupportedWireType(wireType)
            }
        }
    }
}
