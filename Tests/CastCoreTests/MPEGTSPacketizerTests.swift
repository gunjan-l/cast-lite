import XCTest
import Foundation
@testable import CastCore

final class MPEGTSPacketizerTests: XCTestCase {

    private func unit(_ seconds: Double, keyframe: Bool) -> AccessUnit {
        AccessUnit(annexB: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]),
                   pts: PTS90kHz(seconds: seconds), isKeyframe: keyframe)
    }

    func testMPEGTSPacketSyncByteAndLength() {
        let packetizer = MPEGTSPacketizer()
        let patPacket = packetizer.generatePAT()

        XCTAssertEqual(patPacket.count, 188)
        XCTAssertEqual(patPacket[0], 0x47) // Sync byte

        let pmtPacket = packetizer.generatePMT()
        XCTAssertEqual(pmtPacket.count, 188)
        XCTAssertEqual(pmtPacket[0], 0x47) // Sync byte
    }

    func testPacketizerPIDMapping() {
        let packetizer = MPEGTSPacketizer()
        let pat = packetizer.generatePAT()
        // PID 0 is 13 bits starting at byte 1 bit 5
        let patPID = ((UInt16(pat[1] & 0x1F) << 8) | UInt16(pat[2]))
        XCTAssertEqual(patPID, 0x0000)

        let pmt = packetizer.generatePMT()
        let pmtPID = ((UInt16(pmt[1] & 0x1F) << 8) | UInt16(pmt[2]))
        XCTAssertEqual(pmtPID, MPEGTSPacketizer.pmtPID)
    }

    func testContinuityCounterIncrements() {
        let packetizer = MPEGTSPacketizer()

        let packets = packetizer.packetizeVideo(unit(1.0, keyframe: true))
        XCTAssertGreaterThanOrEqual(packets.count, 1)
        for packet in packets {
            XCTAssertEqual(packet.count, 188)
            XCTAssertEqual(packet[0], 0x47)
        }

        let packets2 = packetizer.packetizeVideo(unit(1.1, keyframe: false))
        XCTAssertGreaterThanOrEqual(packets2.count, 1)
        let cc1 = packets.last![3] & 0x0F
        let cc2 = packets2[0][3] & 0x0F
        XCTAssertEqual((cc1 + 1) & 0x0F, cc2)
    }
}
