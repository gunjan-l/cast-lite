import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CastCore

final class MirrorStreamTests: XCTestCase {

    // MARK: - Helpers

    private let sps = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x4D, 0x40, 0x1F])
    private let pps = Data([0x00, 0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C, 0x80])

    private func keyframe(at seconds: Double) -> AccessUnit {
        var data = sps
        data.append(pps)
        data.append(Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00, 0x10]))
        return AccessUnit(annexB: data, pts: PTS90kHz(seconds: seconds), isKeyframe: true)
    }

    private func delta(at seconds: Double) -> AccessUnit {
        AccessUnit(
            annexB: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x00, 0x20]),
            pts: PTS90kHz(seconds: seconds),
            isKeyframe: false
        )
    }

    /// Feeds GOPs whose keyframes land at `keyframeTimes`; each GOP gets delta frames every 0.25 s.
    private func feed(_ stream: MirrorStream, keyframeTimes: [Double]) {
        for (index, start) in keyframeTimes.enumerated() {
            stream.append(keyframe(at: start))
            guard index + 1 < keyframeTimes.count else { continue }
            var t = start + 0.25
            while t < keyframeTimes[index + 1] - 0.001 {
                stream.append(delta(at: t))
                t += 0.25
            }
        }
    }

    private func get(_ port: UInt16, _ path: String) async throws -> (status: Int, headers: HTTPURLResponse, body: Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        return (http.statusCode, http, data)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func extinfDurations(_ playlist: String) -> [Double] {
        playlist.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst(8).dropLast())
        }
    }

    private func segmentNames(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".ts") }
    }

    // MARK: - TS parsing (independent reader of the served bytes)

    private struct TSPacket {
        let pid: UInt16
        let pusi: Bool
        let cc: UInt8
        let adaptation: Data
        let payload: Data
    }

    private func parseTS(_ data: Data) -> [TSPacket] {
        var packets: [TSPacket] = []
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes.count % 188, 0)
        var i = 0
        while i + 188 <= bytes.count {
            XCTAssertEqual(bytes[i], 0x47)
            let pid = (UInt16(bytes[i + 1] & 0x1F) << 8) | UInt16(bytes[i + 2])
            let control = (bytes[i + 3] >> 4) & 0x3
            var payloadStart = i + 4
            var adaptation = Data()
            if control & 0x2 != 0 {
                let len = Int(bytes[i + 4])
                adaptation = Data(bytes[(i + 5)..<(i + 5 + len)])
                payloadStart = i + 5 + len
            }
            let payload = control & 0x1 != 0 ? Data(bytes[payloadStart..<(i + 188)]) : Data()
            packets.append(TSPacket(pid: pid, pusi: bytes[i + 1] & 0x40 != 0, cc: bytes[i + 3] & 0x0F,
                                    adaptation: adaptation, payload: payload))
            i += 188
        }
        return packets
    }

    /// Elementary-stream bytes of each PES packet on the video PID.
    private func videoUnits(_ packets: [TSPacket]) -> [Data] {
        var units: [Data] = []
        for p in packets where p.pid == MPEGTSPacketizer.videoPID {
            if p.pusi { units.append(Data()) }
            units[units.count - 1].append(p.payload)
        }
        return units.map { pes in
            let headerLength = Int(pes[8])
            return pes.dropFirst(9 + headerLength)
        }.map { Data($0) }
    }

    private func startedStream(window: Int = 6) async throws -> (MirrorStream, UInt16) {
        let stream = MirrorStream(port: 0, windowSize: window)
        let port = try await stream.start()
        return (stream, port)
    }

    // MARK: - Playlist availability

    func testPlaylistIsNotServedUntilFirstSegmentCompletes() async throws {
        let (stream, port) = try await startedStream()

        var r = try await get(port, "/stream.m3u8")
        XCTAssertEqual(r.status, 404)

        // A segment only completes when the next keyframe arrives.
        feed(stream, keyframeTimes: [0])
        stream.append(delta(at: 0.5))
        stream.append(delta(at: 0.9))
        r = try await get(port, "/stream.m3u8")
        XCTAssertEqual(r.status, 404)

        stream.append(keyframe(at: 1.0))
        r = try await get(port, "/stream.m3u8")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl")
        XCTAssertTrue(text(r.body).contains("segment0.ts"))
        await stream.stop()
    }

    // MARK: - Segmenting

    func testSegmentsAreCutOnlyAtKeyframes() async throws {
        let (stream, port) = try await startedStream()
        // Second GOP is 2.5 s long; delta frames must never start a segment.
        feed(stream, keyframeTimes: [0, 1, 3.5, 4.5])

        let playlist = text(try await get(port, "/stream.m3u8").body)
        let names = segmentNames(playlist)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(extinfDurations(playlist), [1.0, 2.5, 1.0])

        for name in names {
            let seg = try await get(port, "/\(name)")
            XCTAssertEqual(seg.status, 200)
            XCTAssertEqual(seg.headers.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
            let units = videoUnits(parseTS(seg.body))
            XCTAssertGreaterThan(units.count, 1)
            // AUD (type 9) leads every access unit.
            for unit in units { XCTAssertEqual(Array(unit.prefix(6)), [0, 0, 0, 1, 0x09, 0xF0]) }
            XCTAssertTrue(units[0].contains(0x65), "segment must open with the IDR")
            for unit in units.dropFirst() {
                XCTAssertFalse(unit.contains(0x65), "only the first unit of a segment may be a keyframe")
            }
        }
        await stream.stop()
    }

    func testSegmentsStartWithPATAndVideoOnlyPMTAndKeyframeHasPCR() async throws {
        let (stream, port) = try await startedStream()
        feed(stream, keyframeTimes: [0, 1, 2])

        let seg = try await get(port, "/segment0.ts")
        let packets = parseTS(seg.body)
        XCTAssertEqual(packets[0].pid, MPEGTSPacketizer.patPID)
        XCTAssertEqual(packets[1].pid, MPEGTSPacketizer.pmtPID)
        // PMT: single elementary stream, H.264 (0x1B). Section length 18 leaves room for exactly one.
        let pmt = [UInt8](packets[1].payload)
        XCTAssertEqual(pmt[1], 0x02)
        XCTAssertEqual(pmt[3], 0x12)
        XCTAssertEqual(pmt[13], 0x1B)
        XCTAssertEqual(pmt[22], 0xFF, "no second elementary stream after the CRC")

        let firstVideo = packets[2]
        XCTAssertEqual(firstVideo.pid, MPEGTSPacketizer.videoPID)
        XCTAssertTrue(firstVideo.pusi)
        XCTAssertGreaterThanOrEqual(firstVideo.adaptation.count, 7)
        XCTAssertEqual(firstVideo.adaptation[0] & 0x10, 0x10, "PCR flag on keyframe packet")
        await stream.stop()
    }

    func testContinuityCountersCarryAcrossSegments() async throws {
        let (stream, port) = try await startedStream()
        feed(stream, keyframeTimes: [0, 1, 2, 3])

        var previous: [UInt16: UInt8] = [:]
        for index in 0..<3 {
            let packets = parseTS(try await get(port, "/segment\(index).ts").body)
            for p in packets {
                if let last = previous[p.pid] {
                    XCTAssertEqual(p.cc, (last + 1) & 0x0F, "pid \(p.pid) segment \(index)")
                }
                previous[p.pid] = p.cc
            }
        }
        await stream.stop()
    }

    func testTargetDurationIsCeilingOfLongestSegment() async throws {
        let (stream, port) = try await startedStream()
        feed(stream, keyframeTimes: [0, 1, 3.5, 4.5])

        let playlist = text(try await get(port, "/stream.m3u8").body)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:3\n"), playlist)
        await stream.stop()
    }

    func testWindowSlidesAndOldSegmentsAreGone() async throws {
        let (stream, port) = try await startedStream(window: 6)
        feed(stream, keyframeTimes: (0...8).map(Double.init)) // 8 complete segments

        let playlist = text(try await get(port, "/stream.m3u8").body)
        XCTAssertEqual(segmentNames(playlist), (2...7).map { "segment\($0).ts" })
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:2\n"))

        let old = try await get(port, "/segment0.ts")
        XCTAssertEqual(old.status, 404)
        let newest = try await get(port, "/segment7.ts")
        XCTAssertEqual(newest.status, 200)
        await stream.stop()
    }

    // MARK: - Viewer, hls.js, debug

    func testViewAndHlsJsAreServedWithCorrectContentTypes() async throws {
        let (stream, port) = try await startedStream()

        let view = try await get(port, "/view")
        XCTAssertEqual(view.status, 200)
        XCTAssertTrue(view.headers.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = text(view.body)
        XCTAssertTrue(html.contains("/stream.m3u8"))
        XCTAssertTrue(html.contains("/hls.js"))
        XCTAssertTrue(html.lowercased().contains("waiting for stream"))

        let js = try await get(port, "/hls.js")
        XCTAssertEqual(js.status, 200)
        XCTAssertTrue(js.headers.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/javascript") == true)
        XCTAssertGreaterThan(js.body.count, 100_000)
        XCTAssertTrue(text(js.body).contains("Hls"))
        await stream.stop()
    }

    func testDebugReportsPhaseAndSegmentCount() async throws {
        let (stream, port) = try await startedStream()

        func debug() async throws -> [String: Any] {
            let r = try await get(port, "/debug")
            XCTAssertEqual(r.status, 200)
            XCTAssertTrue(r.headers.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
            return try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        }

        var info = try await debug()
        XCTAssertEqual(info["phase"] as? String, "waiting-for-stream")
        XCTAssertEqual(info["segmentCount"] as? Int, 0)

        feed(stream, keyframeTimes: [0, 1, 2])
        info = try await debug()
        XCTAssertEqual(info["phase"] as? String, "streaming")
        XCTAssertEqual(info["segmentCount"] as? Int, 2)

        let snapshot = stream.status()
        XCTAssertEqual(snapshot.phase, .streaming)
        XCTAssertEqual(snapshot.segmentCount, 2)
        XCTAssertEqual(snapshot.port, port)
        await stream.stop()
        XCTAssertEqual(stream.status().phase, .stopped)
    }

    func testMJPEGAndFrameRoutesAreGone() async throws {
        let (stream, port) = try await startedStream()
        for path in ["/stream", "/frame", "/status"] {
            let r = try await get(port, path)
            XCTAssertEqual(r.status, 404, path)
        }
        await stream.stop()
    }
}
