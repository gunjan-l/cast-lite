import XCTest
@testable import CastCore

final class AnnexBSplitterTests: XCTestCase {
    private let sc4: [UInt8] = [0, 0, 0, 1]
    private let sc3: [UInt8] = [0, 0, 1]

    // header byte, then slice header starting with first_mb_in_slice=0 (bit 1)
    private func idr() -> [UInt8] { sc4 + [0x65, 0x88, 0x84, 0x10] }
    private func p() -> [UInt8] { sc3 + [0x41, 0x9A, 0x22] }
    private func sps() -> [UInt8] { sc4 + [0x67, 0x42, 0x00, 0x1F] }
    private func pps() -> [UInt8] { sc4 + [0x68, 0xCE, 0x3C, 0x80] }

    func testSplitsAccessUnitsAndMarksKeyframes() {
        let stream = Data(sps() + pps() + idr() + p() + p() + sps() + pps() + idr())
        let units = AnnexBSplitter.accessUnits(from: stream, framesPerSecond: 30)
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(units.map(\.isKeyframe), [true, false, false, true])
        XCTAssertEqual(units[0].annexB, Data(sps() + pps() + idr()))
        XCTAssertEqual(units[1].annexB, Data(p()))
        XCTAssertEqual(units.reduce(0) { $0 + $1.annexB.count }, stream.count)
    }

    func testPTSAdvancesBy3000TicksAt30fps() {
        let stream = Data(idr() + p() + p())
        let units = AnnexBSplitter.accessUnits(from: stream, framesPerSecond: 30)
        XCTAssertEqual(units.map(\.pts.ticks), [0, 3000, 6000])
    }

    func testMultiSliceFrameStaysOneAccessUnit() {
        let continuation = sc3 + [0x41, 0x1A, 0x22] // first_mb_in_slice != 0
        let units = AnnexBSplitter.accessUnits(from: Data(p() + continuation + p()), framesPerSecond: 25)
        XCTAssertEqual(units.count, 2)
    }

    func testEmptyInputYieldsNoUnits() {
        XCTAssertTrue(AnnexBSplitter.accessUnits(from: Data(), framesPerSecond: 30).isEmpty)
    }
}
