import XCTest
@testable import CastCore

final class CastPacketFramerTests: XCTestCase {

    func testFramePayloadPrependsFourByteBigEndianLength() {
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let framed = CastPacketFramer.frame(payload: payload)

        XCTAssertEqual(framed.count, 9)
        // Length 5 in big endian: 0x00, 0x00, 0x00, 0x05
        XCTAssertEqual(framed[0], 0x00)
        XCTAssertEqual(framed[1], 0x00)
        XCTAssertEqual(framed[2], 0x00)
        XCTAssertEqual(framed[3], 0x05)
        XCTAssertEqual(framed.subdata(in: 4..<9), payload)
    }

    func testFrameMessageEncodesAndFrames() throws {
        let message = CastMessage(
            sourceId: "src",
            destinationId: "dst",
            namespace: "ns",
            payloadType: .string,
            payloadUtf8: "{}"
        )

        let framed = try CastPacketFramer.frame(message: message)
        let payload = try CastMessageCodec.encode(message)

        XCTAssertEqual(framed.count, 4 + payload.count)
        let length = framed.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), payload.count)
        XCTAssertEqual(framed.subdata(in: 4..<framed.count), payload)
    }

    func testUnframeCompleteSinglePacket() throws {
        var framer = CastPacketFramer()
        let payload = Data("hello cast".utf8)
        let framed = CastPacketFramer.frame(payload: payload)

        let packets = try framer.append(framed)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first, payload)
        XCTAssertTrue(framer.isEmpty)
    }

    func testUnframeMultipleConcatenatedPackets() throws {
        var framer = CastPacketFramer()
        let payload1 = Data("first message".utf8)
        let payload2 = Data("second message".utf8)
        var streamData = Data()
        streamData.append(CastPacketFramer.frame(payload: payload1))
        streamData.append(CastPacketFramer.frame(payload: payload2))

        let packets = try framer.append(streamData)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], payload1)
        XCTAssertEqual(packets[1], payload2)
        XCTAssertTrue(framer.isEmpty)
    }

    func testUnframeFragmentedHeaderAndPayload() throws {
        var framer = CastPacketFramer()
        let payload = Data("fragmented stream testing".utf8)
        let framed = CastPacketFramer.frame(payload: payload)

        // Split into 3 arbitrary chunks:
        // Chunk 1: first 2 bytes of the 4-byte header
        // Chunk 2: next 2 bytes of header + first 5 bytes of payload
        // Chunk 3: remaining bytes of payload
        let chunk1 = framed.subdata(in: 0..<2)
        let chunk2 = framed.subdata(in: 2..<9)
        let chunk3 = framed.subdata(in: 9..<framed.count)

        let packets1 = try framer.append(chunk1)
        XCTAssertTrue(packets1.isEmpty)
        XCTAssertFalse(framer.isEmpty)

        let packets2 = try framer.append(chunk2)
        XCTAssertTrue(packets2.isEmpty)

        let packets3 = try framer.append(chunk3)
        XCTAssertEqual(packets3.count, 1)
        XCTAssertEqual(packets3.first, payload)
        XCTAssertTrue(framer.isEmpty)
    }

    func testUnframeByteByByteStreaming() throws {
        var framer = CastPacketFramer()
        let payload = Data("byte by byte test".utf8)
        let framed = CastPacketFramer.frame(payload: payload)

        var accumulatedPackets: [Data] = []
        for byte in framed {
            let packets = try framer.append(Data([byte]))
            accumulatedPackets.append(contentsOf: packets)
        }

        XCTAssertEqual(accumulatedPackets.count, 1)
        XCTAssertEqual(accumulatedPackets.first, payload)
        XCTAssertTrue(framer.isEmpty)
    }

    func testUnframePacketExceedingMaximumSizeThrows() {
        var framer = CastPacketFramer()
        // 4 bytes indicating 10MB packet (0x00A00000 = 10,485,760 bytes)
        var invalidHeader = Data()
        let size: UInt32 = 10 * 1024 * 1024
        var bigEndianSize = size.bigEndian
        invalidHeader.append(Data(bytes: &bigEndianSize, count: 4))

        XCTAssertThrowsError(try framer.append(invalidHeader)) { error in
            guard let framerError = error as? CastFramerError else {
                XCTFail("Expected CastFramerError, got \(error)")
                return
            }
            if case .packetExceedsMaximumSize(let length) = framerError {
                XCTAssertEqual(length, size)
            } else {
                XCTFail("Expected packetExceedsMaximumSize, got \(framerError)")
            }
        }
    }

    func testFramerResetClearsBuffer() throws {
        var framer = CastPacketFramer()
        // Feed partial data
        _ = try framer.append(Data([0x00, 0x00]))
        XCTAssertFalse(framer.isEmpty)
        XCTAssertEqual(framer.bufferedBytesCount, 2)

        framer.reset()
        XCTAssertTrue(framer.isEmpty)
        XCTAssertEqual(framer.bufferedBytesCount, 0)
    }

    func testFramerCustomMaxPacketLength() {
        var framer = CastPacketFramer(maxPacketLength: 100)
        var invalidHeader = Data()
        let size: UInt32 = 101
        var bigEndianSize = size.bigEndian
        invalidHeader.append(Data(bytes: &bigEndianSize, count: 4))

        XCTAssertThrowsError(try framer.append(invalidHeader)) { error in
            guard let framerError = error as? CastFramerError,
                  case .packetExceedsMaximumSize(let length) = framerError else {
                XCTFail("Expected packetExceedsMaximumSize, got \(error)")
                return
            }
            XCTAssertEqual(length, 101)
        }
    }

    func testFramerHandlesNonZeroStartIndexAndOddSlices() throws {
        var framer = CastPacketFramer()
        let payload1 = Data("odd1".utf8)
        let payload2 = Data("odd22".utf8)
        var streamData = Data([0xEE]) // 1 junk byte to create odd offset
        streamData.append(CastPacketFramer.frame(payload: payload1))
        streamData.append(CastPacketFramer.frame(payload: payload2))

        // Slice ignoring first byte
        let slice = streamData.subdata(in: 1..<streamData.count)

        let packets = try framer.append(slice)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], payload1)
        XCTAssertEqual(packets[1], payload2)
    }
}
