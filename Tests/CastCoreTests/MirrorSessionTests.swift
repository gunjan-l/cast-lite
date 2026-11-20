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

    // MARK: - Casting

    private typealias Receiver = CastSessionCoordinatorTests.MockChromecastDevice

    private func castSession(_ receiver: Receiver, discovered: [DiscoveredDevice] = []) -> MirrorSession {
        MirrorSession(
            port: 0,
            discoveryFallback: { discovered },
            castTransportFactory: { _ in receiver.transport },
            hostResolver: { "192.168.1.20" }
        )
    }

    private func castPayloads(_ receiver: Receiver, namespace: String, type: String) -> [[String: Any]] {
        receiver.sentMessages.compactMap { msg in
            guard msg.namespace == namespace, let s = msg.payloadUtf8,
                  let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                  json["type"] as? String == type else { return nil }
            return json
        }
    }

    func testSelectedDeviceSendsConnectLaunchAndLoadOfStreamURL() async throws {
        let receiver = Receiver()
        let session = castSession(receiver)
        _ = try await session.start(handoff: MirrorHandoff(selection: .device(tv("chosen")), quality: .high))
        feedTwoSegments(session)
        await session.awaitCastSettled()

        let port = session.status().port
        XCTAssertFalse(castPayloads(receiver, namespace: CastNamespaces.connection, type: "CONNECT").isEmpty)
        XCTAssertEqual(castPayloads(receiver, namespace: CastNamespaces.receiver, type: "LAUNCH").count, 1)
        let loads = castPayloads(receiver, namespace: CastNamespaces.media, type: "LOAD")
        XCTAssertEqual(loads.count, 1)
        let media = loads.first?["media"] as? [String: Any]
        XCTAssertEqual(media?["contentId"] as? String, "http://192.168.1.20:\(port)/stream.m3u8")
        XCTAssertEqual(session.status().castPhase, .playing)
        await session.stop()
    }

    func testNoHandoffAndOneTVCastsToIt() async throws {
        let receiver = Receiver()
        let session = castSession(receiver, discovered: [tv("only")])
        _ = try await session.start(handoff: nil)
        feedTwoSegments(session)
        await session.awaitCastSettled()

        XCTAssertEqual(castPayloads(receiver, namespace: CastNamespaces.media, type: "LOAD").count, 1)
        XCTAssertEqual(session.status().castPhase, .playing)
        await session.stop()
    }

    func testCastFailureLeavesHTTPRoutesServingAndReportsError() async throws {
        let receiver = Receiver()
        receiver.loadBehavior = .loadFailed("bad stream")
        let session = castSession(receiver)
        _ = try await session.start(handoff: MirrorHandoff(selection: .device(tv("chosen")), quality: .high))
        feedTwoSegments(session)
        await session.awaitCastSettled()

        let status = session.status()
        XCTAssertEqual(status.castPhase, .failed(.loadFailed("bad stream")))
        XCTAssertEqual(status.lastError, CastFailure.loadFailed("bad stream").message)
        XCTAssertNotEqual(status.phase, .failed)
        let info = try await debug(status.port)
        XCTAssertEqual(info["castPhase"] as? String, "failed")
        XCTAssertEqual(info["lastError"] as? String, CastFailure.loadFailed("bad stream").message)
        await session.stop()
    }

    func testStartReturnsImmediatelyAndLoadWaitsForFirstSegment() async throws {
        let receiver = Receiver()
        let session = castSession(receiver)
        let url = try await session.start(handoff: MirrorHandoff(selection: .device(tv("chosen")), quality: .high))

        // start() returned with the viewer URL while Cast is still waiting for the first segment.
        XCTAssertTrue(url.hasSuffix("/view"))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.status().segmentCount, 0)
        XCTAssertTrue(receiver.sentMessages.isEmpty, "no Cast traffic (CONNECT/LAUNCH/LOAD) before the playlist exists")
        XCTAssertNotEqual(session.status().castPhase, .playing)

        feedTwoSegments(session)
        await session.awaitCastSettled()

        XCTAssertEqual(castPayloads(receiver, namespace: CastNamespaces.media, type: "LOAD").count, 1)
        XCTAssertEqual(session.status().castPhase, .playing)
        await session.stop()
    }

    func testStopBeforeFirstSegmentNeverSendsLoad() async throws {
        let receiver = Receiver()
        let session = castSession(receiver)
        _ = try await session.start(handoff: MirrorHandoff(selection: .device(tv("chosen")), quality: .high))
        await session.stop()
        await session.awaitCastSettled()

        XCTAssertTrue(castPayloads(receiver, namespace: CastNamespaces.media, type: "LOAD").isEmpty)
    }

    func testStopSendsMediaStopAndClosesReceiverApp() async throws {
        let receiver = Receiver()
        let session = castSession(receiver)
        _ = try await session.start(handoff: MirrorHandoff(selection: .device(tv("chosen")), quality: .high))
        feedTwoSegments(session)
        await session.awaitCastSettled()
        let port = session.status().port

        await session.stop()

        let stops = castPayloads(receiver, namespace: CastNamespaces.media, type: "STOP")
        XCTAssertEqual(stops.first?["mediaSessionId"] as? Int, 1234)
        let appStops = castPayloads(receiver, namespace: CastNamespaces.receiver, type: "STOP")
        XCTAssertEqual(appStops.first?["sessionId"] as? String, "mock-sess-001")
        XCTAssertEqual(session.status().phase, .ended)
        XCTAssertEqual(session.status().castPhase, .ended("stopped"))
        do {
            _ = try await debug(port)
            XCTFail("server should be down")
        } catch {}
    }
}