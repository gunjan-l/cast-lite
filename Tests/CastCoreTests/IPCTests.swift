import XCTest
import Foundation
@testable import CastCore

private final class PacketBox: @unchecked Sendable {
    var packet: IPCPacket?
    private let lock = NSLock()

    func set(_ p: IPCPacket) {
        lock.lock()
        defer { lock.unlock() }
        packet = p
    }

    func get() -> IPCPacket? {
        lock.lock()
        defer { lock.unlock() }
        return packet
    }
}

final class IPCTests: XCTestCase {

    func testIPCPacketSerializationAndDeserializationVideo() {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E]) // Sample NAL unit
        let originalPacket = IPCPacket(
            type: .video,
            isKeyframe: true,
            timestamp: 1234567890,
            payload: payload
        )

        let binaryData = originalPacket.serialize()
        XCTAssertGreaterThan(binaryData.count, 14)

        let parsedPacket = IPCPacket.deserialize(from: binaryData)
        XCTAssertNotNil(parsedPacket)
        XCTAssertEqual(parsedPacket?.type, .video)
        XCTAssertEqual(parsedPacket?.isKeyframe, true)
        XCTAssertEqual(parsedPacket?.timestamp, 1234567890)
        XCTAssertEqual(parsedPacket?.payload, payload)
    }

    func testIPCPacketDeserializationInvalidMagic() {
        var invalidData = Data([0x00, 0x00, 0x00, 0x00]) // Bad magic
        invalidData.append(Data(repeating: 0xFF, count: 20))
        let parsed = IPCPacket.deserialize(from: invalidData)
        XCTAssertNil(parsed)
    }

    func testMJPEGMultipartBoundaryAndHeaders() {
        let boundary = "--castliteframe"
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0xFF, 0xD9])
        let frameData = MJPEGStreamFormatter.formatFrame(jpegData: jpegData, boundary: boundary)
        let frameString = String(decoding: frameData, as: UTF8.self)

        XCTAssertTrue(frameString.hasPrefix(boundary + "\r\n"))
        XCTAssertTrue(frameString.contains("Content-Type: image/jpeg\r\n"))
        XCTAssertTrue(frameString.contains("Content-Length: \(jpegData.count)\r\n\r\n"))
    }

    func testIPCServerClientLoopback() async throws {
        let server = IPCServer()
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)

        let box = PacketBox()
        let expectation = expectation(description: "Packet received by IPCServer")

        await server.setOnPacketReceived { packet in
            box.set(packet)
            expectation.fulfill()
        }

        let client = IPCClient()
        let connected = try await client.connect(port: port)
        XCTAssertTrue(connected)

        let testPayload = Data("live-h264-nalu".utf8)
        let packetToSend = IPCPacket(type: .video, isKeyframe: false, timestamp: 9999, payload: testPayload)
        try await client.send(packet: packetToSend)

        await fulfillment(of: [expectation], timeout: 2.0)

        let received = box.get()
        XCTAssertNotNil(received)
        XCTAssertEqual(received?.type, .video)
        XCTAssertEqual(received?.payload, testPayload)

        await client.disconnect()
        await server.stop()
    }
}
