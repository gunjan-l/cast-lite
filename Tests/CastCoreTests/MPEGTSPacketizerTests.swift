import XCTest
import Foundation
@testable import CastCore

final class MPEGTSPacketizerTests: XCTestCase {

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
        let nalu = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]) // Sample IDR NALU

        let packets = packetizer.packetizeVideo(nalu: nalu, pts: 90000, isKeyframe: true)
        XCTAssertGreaterThanOrEqual(packets.count, 1)

        for packet in packets {
            XCTAssertEqual(packet.count, 188)
            XCTAssertEqual(packet[0], 0x47)
        }

        // Check continuity counter in second packetization
        let packets2 = packetizer.packetizeVideo(nalu: nalu, pts: 93000, isKeyframe: false)
        XCTAssertGreaterThanOrEqual(packets2.count, 1)
        let cc1 = packets[0][3] & 0x0F
        let cc2 = packets2[0][3] & 0x0F
        XCTAssertEqual((cc1 + 1) & 0x0F, cc2)
    }

    func testHLSSegmenterGeneratesLiveSlidingWindowPlaylist() {
        let segmenter = HLSSegmenter(targetDuration: 1, windowSize: 3)

        segmenter.addSegment(data: Data(repeating: 0x47, count: 188 * 5), duration: 1.0)
        segmenter.addSegment(data: Data(repeating: 0x47, count: 188 * 5), duration: 1.0)
        segmenter.addSegment(data: Data(repeating: 0x47, count: 188 * 5), duration: 1.0)

        let m3u8 = segmenter.generatePlaylist()
        XCTAssertTrue(m3u8.contains("#EXTM3U"))
        XCTAssertTrue(m3u8.contains("#EXT-X-TARGETDURATION:1"))
        XCTAssertTrue(m3u8.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(m3u8.contains("segment0.ts"))
        XCTAssertTrue(m3u8.contains("segment1.ts"))
        XCTAssertTrue(m3u8.contains("segment2.ts"))

        // Add 4th segment - should slide window
        segmenter.addSegment(data: Data(repeating: 0x47, count: 188 * 5), duration: 1.0)
        let m3u8Slide = segmenter.generatePlaylist()
        XCTAssertTrue(m3u8Slide.contains("#EXT-X-MEDIA-SEQUENCE:1"))
        XCTAssertFalse(m3u8Slide.contains("segment0.ts"))
        XCTAssertTrue(m3u8Slide.contains("segment3.ts"))
    }
}
