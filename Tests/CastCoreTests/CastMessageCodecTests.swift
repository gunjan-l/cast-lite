import XCTest
@testable import CastCore

final class CastMessageCodecTests: XCTestCase {

    // MARK: - Serialization Tests

    func testEncodeCastMessageBasic() throws {
        let message = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.tp.connection",
            payloadType: .string,
            payloadUtf8: "{\"type\":\"CONNECT\"}"
        )

        let encoded = try CastMessageCodec.encode(message)
        XCTAssertFalse(encoded.isEmpty)

        // Decode back
        let decoded = try CastMessageCodec.decode(encoded)
        XCTAssertEqual(decoded.protocolVersion, .castv2_1_0)
        XCTAssertEqual(decoded.sourceId, "sender-0")
        XCTAssertEqual(decoded.destinationId, "receiver-0")
        XCTAssertEqual(decoded.namespace, "urn:x-cast:com.google.cast.tp.connection")
        XCTAssertEqual(decoded.payloadType, .string)
        XCTAssertEqual(decoded.payloadUtf8, "{\"type\":\"CONNECT\"}")
        XCTAssertNil(decoded.payloadBinary)
    }

    func testEncodeCastMessageBinaryPayload() throws {
        let binaryData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let message = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "sender-1",
            destinationId: "receiver-1",
            namespace: "urn:x-cast:com.google.cast.tp.media",
            payloadType: .binary,
            payloadBinary: binaryData
        )

        let encoded = try CastMessageCodec.encode(message)
        let decoded = try CastMessageCodec.decode(encoded)

        XCTAssertEqual(decoded.protocolVersion, .castv2_1_0)
        XCTAssertEqual(decoded.sourceId, "sender-1")
        XCTAssertEqual(decoded.destinationId, "receiver-1")
        XCTAssertEqual(decoded.namespace, "urn:x-cast:com.google.cast.tp.media")
        XCTAssertEqual(decoded.payloadType, .binary)
        XCTAssertEqual(decoded.payloadBinary, binaryData)
        XCTAssertNil(decoded.payloadUtf8)
    }

    func testProtobufWireFormatFieldTags() throws {
        let message = CastMessage(
            protocolVersion: .castv2_1_0,
            sourceId: "a",
            destinationId: "b",
            namespace: "c",
            payloadType: .string,
            payloadUtf8: "d"
        )

        let encoded = try CastMessageCodec.encode(message)

        // Field 1 tag: (1 << 3) | 0 = 0x08, value 0x00
        // Field 2 tag: (2 << 3) | 2 = 0x12, len 1 (0x01), byte 'a' (0x61)
        // Field 3 tag: (3 << 3) | 2 = 0x1a, len 1 (0x01), byte 'b' (0x62)
        // Field 4 tag: (4 << 3) | 2 = 0x22, len 1 (0x01), byte 'c' (0x63)
        // Field 5 tag: (5 << 3) | 0 = 0x28, value 0x00
        // Field 6 tag: (6 << 3) | 2 = 0x32, len 1 (0x01), byte 'd' (0x64)
        let expectedBytes: [UInt8] = [
            0x08, 0x00,
            0x12, 0x01, 0x61,
            0x1a, 0x01, 0x62,
            0x22, 0x01, 0x63,
            0x28, 0x00,
            0x32, 0x01, 0x64
        ]

        XCTAssertEqual(Array(encoded), expectedBytes)
    }

    // MARK: - Deserialization Error Handling Tests

    func testDecodeEmptyDataThrows() {
        XCTAssertThrowsError(try CastMessageCodec.decode(Data())) { error in
            guard let codecError = error as? CastCodecError else {
                XCTFail("Expected CastCodecError, got \(error)")
                return
            }
            if case .missingRequiredField = codecError {
                // pass
            } else {
                XCTFail("Expected missingRequiredField, got \(codecError)")
            }
        }
    }

    func testDecodeTruncatedVarintThrows() {
        // Tag with continuation bit set (0x80) but no subsequent bytes
        let truncatedData = Data([0x88])
        XCTAssertThrowsError(try CastMessageCodec.decode(truncatedData)) { error in
            XCTAssertTrue(error is CastCodecError)
        }
    }

    func testDecodeTruncatedLengthDelimitedThrows() {
        // Tag 0x12 (source_id), length 10 (0x0A), but only 2 bytes provided
        let truncatedData = Data([0x12, 0x0A, 0x61, 0x62])
        XCTAssertThrowsError(try CastMessageCodec.decode(truncatedData)) { error in
            guard let codecError = error as? CastCodecError, case .unexpectedEndOfData = codecError else {
                XCTFail("Expected unexpectedEndOfData, got \(error)")
                return
            }
        }
    }

    func testDecodeVarintLengthExceedsIntMaxThrows() {
        // Tag 0x12 (source_id), length with MSB set (0xFF... 10 bytes)
        let malformedData = Data([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        XCTAssertThrowsError(try CastMessageCodec.decode(malformedData)) { error in
            guard let codecError = error as? CastCodecError, case .unexpectedEndOfData = codecError else {
                XCTFail("Expected unexpectedEndOfData, got \(error)")
                return
            }
        }
    }

    func testDecodeMissingRequiredFieldThrows() {
        // Only protocol_version (0x08, 0x00)
        let partialData = Data([0x08, 0x00])
        XCTAssertThrowsError(try CastMessageCodec.decode(partialData)) { error in
            guard let codecError = error as? CastCodecError, case .missingRequiredField(let field) = codecError else {
                XCTFail("Expected missingRequiredField, got \(error)")
                return
            }
            XCTAssertFalse(field.isEmpty)
        }
    }

    func testDecodeSkipsUnknownFields() throws {
        // Valid message with an extra unknown field 99 (varint: tag = (99 << 3) | 0 = 0x0318 -> varint [0x98, 0x06], value 42 [0x2A])
        let bytes: [UInt8] = [
            0x08, 0x00,
            0x12, 0x01, 0x61,
            0x1a, 0x01, 0x62,
            0x22, 0x01, 0x63,
            0x28, 0x00,
            0x32, 0x01, 0x64,
            0x98, 0x06, 0x2A // Unknown field 99 varint
        ]
        let data = Data(bytes)
        let decoded = try CastMessageCodec.decode(data)
        XCTAssertEqual(decoded.sourceId, "a")
        XCTAssertEqual(decoded.destinationId, "b")
        XCTAssertEqual(decoded.namespace, "c")
        XCTAssertEqual(decoded.payloadUtf8, "d")
    }

    func testDecodeVarintTenthByteGreaterThanOneThrowsMalformedVarint() {
        // Unknown field with a 10-byte varint where the 10th byte is 0x02 (b > 1)
        var bytes: [UInt8] = [
            0x08, 0x00,
            0x12, 0x01, 0x61,
            0x1a, 0x01, 0x62,
            0x22, 0x01, 0x63,
            0x28, 0x00,
            0x32, 0x01, 0x64,
            0x98, 0x06 // Field 99 (wire type 0 varint)
        ]
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02])
        XCTAssertThrowsError(try CastMessageCodec.decode(Data(bytes))) { error in
            guard let codecError = error as? CastCodecError, case .malformedVarint = codecError else {
                XCTFail("Expected malformedVarint, got \(error)")
                return
            }
        }
    }
}
