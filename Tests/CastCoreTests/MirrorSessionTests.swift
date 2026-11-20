import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CastCore

final class MirrorSessionTests: XCTestCase {

    // MARK: - Helpers

    private final class FactoryCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var _devices: [DiscoveredDevice] = []
        func record(_ d: DiscoveredDevice) { lock.lock(); _devices.append(d); lock.unlock() }
        var devices: [DiscoveredDevice] { lock.lock(); defer { lock.unlock() }; return _devices }
    }

    private func tv(_ id: String, ip: String = "192.168.1.50") -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: "TV \(id)", type: .chromecast, ipAddress: ip, port: 8009)
    }

    private func makeSession(
        discovered: [DiscoveredDevice] = [],
        calls: FactoryCalls = FactoryCalls(),
        host: @escaping @Sendable () throws -> String = { "192.168.1.20" }
    ) -> MirrorSession {
        MirrorSession(
            port: 0,
            discoveryFallback: { discovered },
            castTransportFactory: { device in
                calls.record(device)
                return MockCastTransport()
            },
            hostResolver: host
        )
    }

    private func keyframe(at seconds: Double) -> AccessUnit {
        var data = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x4D, 0x40, 0x1F])
        data.append(Data([0x00, 0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C, 0x80]))
        data.append(Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00, 0x10]))
        return AccessUnit(annexB: data, pts: PTS90kHz(seconds: seconds), isKeyframe: true)
    }

    private func delta(at seconds: Double) -> AccessUnit {
        AccessUnit(annexB: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x00, 0x20]),
                   pts: PTS90kHz(seconds: seconds), isKeyframe: false)
    }

    private func feedTwoSegments(_ session: MirrorSession) {
        for k in 0..<3 {
            session.append(keyframe(at: Double(k)))
            session.append(delta(at: Double(k) + 0.5))
        }
    }

    private func debug(_ port: UInt16) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/debug")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Tests

    func testNoneSelectedIsBrowserOnlyAndSendsNoConnect() async throws {
        let calls = FactoryCalls()
        let session = makeSession(discovered: [tv("a")], calls: calls)
        _ = try await session.start(handoff: MirrorHandoff(selection: .noneSelected, quality: .high))

        let status = session.status()
        XCTAssertEqual(status.target, .browserOnly)
        XCTAssertEqual(status.handoffSource, .noneSelected)
        XCTAssertTrue(calls.devices.isEmpty)
        await session.stop()
    }

    func testNoHandoffAndZeroTVsIsBrowserOnlyWithNoHandoffSource() async throws {
        let calls = FactoryCalls()
        let session = makeSession(discovered: [], calls: calls)
        _ = try await session.start(handoff: nil)

        let status = session.status()
        XCTAssertEqual(status.target, .browserOnly)
        XCTAssertEqual(status.handoffSource, .noHandoff)
        XCTAssertEqual(status.handoffSource.description, "no handoff")
        XCTAssertTrue(calls.devices.isEmpty)
        await session.stop()
    }

    func testNoHandoffAndSeveralTVsIsBrowserOnlyWithNoHandoffSource() async throws {
        let calls = FactoryCalls()
        let session = makeSession(discovered: [tv("a"), tv("b", ip: "192.168.1.51")], calls: calls)
        _ = try await session.start(handoff: nil)

        XCTAssertEqual(session.status().target, .browserOnly)
        XCTAssertEqual(session.status().handoffSource, .noHandoff)
        XCTAssertTrue(calls.devices.isEmpty)
        await session.stop()
    }

    func testNoHandoffAndOneTVResolvesToThatTV() async throws {
        let only = tv("only")
        let session = makeSession(discovered: [only])
        _ = try await session.start(handoff: nil)

        XCTAssertEqual(session.status().target, .cast(only))
        XCTAssertEqual(session.status().handoffSource, .noHandoff)
        await session.stop()
    }

    func testSelectedDeviceResolvesToCast() async throws {
        let chosen = tv("chosen")
        let session = makeSession(discovered: [tv("a"), tv("b")])
        _ = try await session.start(handoff: MirrorHandoff(selection: .device(chosen), quality: .lowBandwidth))

        XCTAssertEqual(session.status().target, .cast(chosen))
        XCTAssertEqual(session.status().handoffSource, .selectedDevice(id: "chosen"))
        XCTAssertEqual(session.status().quality, .lowBandwidth)
        await session.stop()
    }

    func testStatusSnapshotReportsPhaseURLSegmentsAndHandoffSource() async throws {
        let session = makeSession()
        let url = try await session.start(handoff: MirrorHandoff(selection: .noneSelected, quality: .high))

        var status = session.status()
        XCTAssertEqual(status.phase, .waitingForStream)
        XCTAssertEqual(status.segmentCount, 0)
        XCTAssertEqual(url, "http://192.168.1.20:\(status.port)/view")
        XCTAssertEqual(status.streamURL, url)
        XCTAssertNil(status.lastError)

        feedTwoSegments(session)
        status = session.status()
        XCTAssertEqual(status.phase, .streaming)
        XCTAssertEqual(status.segmentCount, 2)

        let info = try await debug(status.port)
        XCTAssertEqual(info["phase"] as? String, "streaming")
        XCTAssertEqual(info["segmentCount"] as? Int, 2)
        XCTAssertEqual(info["port"] as? Int, Int(status.port))
        XCTAssertEqual(info["streamURL"] as? String, url)
        XCTAssertEqual(info["handoffSource"] as? String, "none selected")
        XCTAssertTrue(info["lastError"] is NSNull)
        await session.stop()
    }

    func testNoWiFiAddressFailsStartWithTypedErrorAndReleasesServer() async throws {
        let session = makeSession(host: { throw StreamURLError.noWiFiIPv4Address })
        do {
            _ = try await session.start(handoff: nil)
            XCTFail("expected noWiFiIPv4Address")
        } catch {
            XCTAssertEqual(error as? StreamURLError, .noWiFiIPv4Address)
        }
        let status = session.status()
        XCTAssertEqual(status.phase, .failed)
        XCTAssertEqual(status.lastError, StreamURLError.noWiFiIPv4Address.errorDescription)
        XCTAssertNil(status.streamURL)
        XCTAssertEqual(status.port, 0)
    }

    func testStopEndsSessionAndStopsServer() async throws {
        let session = makeSession()
        _ = try await session.start(handoff: nil)
        let port = session.status().port
        XCTAssertNotEqual(port, 0)
        _ = try await debug(port)

        await session.stop()

        XCTAssertEqual(session.status().phase, .ended)
        XCTAssertEqual(session.status().port, 0)
        do {
            _ = try await debug(port)
            XCTFail("server should be down")
        } catch {
            // connection refused: expected
        }
    }
}
