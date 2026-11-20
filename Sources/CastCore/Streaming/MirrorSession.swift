import Foundation

public enum MirrorQuality: String, Sendable, Equatable {
    case high
    case lowBandwidth = "low-bandwidth"
}

/// What the app wrote before the broadcast: a TV or "none", plus the quality mode.
public struct MirrorHandoff: Sendable, Equatable {
    public enum Selection: Sendable, Equatable {
        case device(DiscoveredDevice)
        case noneSelected
    }

    public let selection: Selection
    public let quality: MirrorQuality

    public init(selection: Selection, quality: MirrorQuality) {
        self.selection = selection
        self.quality = quality
    }
}

/// Where the handoff said to send the stream, as observed in the status snapshot.
public enum HandoffSource: Sendable, Equatable, CustomStringConvertible {
    case selectedDevice(id: String)
    case noneSelected
    /// No handoff was readable; the target came from the discovery fallback.
    case noHandoff

    public var description: String {
        switch self {
        case .selectedDevice(let id): return "selected device \(id)"
        case .noneSelected: return "none selected"
        case .noHandoff: return "no handoff"
        }
    }
}

public enum MirrorTarget: Sendable, Equatable {
    case browserOnly
    case cast(DiscoveredDevice)
}

public enum MirrorSessionPhase: String, Sendable, Equatable {
    case idle
    case waitingForStream = "waiting-for-stream"
    case streaming
    case ended
    case failed
}

public struct MirrorSessionStatus: Sendable, Equatable {
    public let phase: MirrorSessionPhase
    /// `http://<wifi-ip>:<port>/view`; nil until started.
    public let streamURL: String?
    /// Bound HTTP port; 0 while not running.
    public let port: UInt16
    public let segmentCount: Int
    public let lastError: String?
    public let handoffSource: HandoffSource
    public let target: MirrorTarget
    public let quality: MirrorQuality
}

/// Owns the lifecycle of one broadcast on top of `MirrorStream`. Platform-neutral; the single test seam.
/// Casting to `.cast` targets is wired in a later ticket; for now the resolved target is only reported.
public final class MirrorSession: @unchecked Sendable {
    public typealias DiscoveryFallback = @Sendable () async -> [DiscoveredDevice]
    public typealias CastTransportFactory = @Sendable (DiscoveredDevice) -> CastTransport
    public typealias HostResolver = @Sendable () throws -> String

    private let stream: MirrorStream
    private let discoveryFallback: DiscoveryFallback
    let castTransportFactory: CastTransportFactory?
    private let hostResolver: HostResolver

    private let lock = NSLock()
    private var ended = false
    private var failed = false
    private var started = false
    private var streamURL: String?
    private var lastError: String?
    private var handoffSource: HandoffSource = .noHandoff
    private var target: MirrorTarget = .browserOnly
    private var quality: MirrorQuality = .high

    public init(
        port: UInt16 = 8080,
        discoveryFallback: @escaping DiscoveryFallback = { [] },
        castTransportFactory: CastTransportFactory? = nil,
        hostResolver: @escaping HostResolver = { try NetworkInterfaceHelper.shared.resolveStreamIP().host }
    ) {
        self.stream = MirrorStream(port: port)
        self.discoveryFallback = discoveryFallback
        self.castTransportFactory = castTransportFactory
        self.hostResolver = hostResolver
        stream.setDebugProvider { [weak self] in self?.debugJSON() ?? Data("{}".utf8) }
    }

    /// Resolves the target, starts the HTTP server and stream, and returns the browser viewer URL.
    /// Throws `StreamURLError.noWiFiIPv4Address` (and releases the server) when no Wi-Fi address exists.
    @discardableResult
    public func start(handoff: MirrorHandoff?) async throws -> String {
        lock.lock()
        if started, let url = streamURL { lock.unlock(); return url }
        started = true
        ended = false
        failed = false
        lastError = nil
        lock.unlock()

        let (resolvedTarget, source) = await resolveTarget(handoff)
        lock.lock()
        target = resolvedTarget
        handoffSource = source
        quality = handoff?.quality ?? .high
        lock.unlock()

        do {
            let port = try await stream.start()
            let host: String
            do {
                host = try hostResolver()
            } catch {
                await stream.stop()
                throw error
            }
            let url = NetworkInterfaceHelper.formatStreamURL(host: host, port: port, path: "view")
            lock.lock(); streamURL = url; lock.unlock()
            return url
        } catch {
            lock.lock()
            failed = true
            started = false
            lastError = error.localizedDescription
            lock.unlock()
            throw error
        }
    }

    /// Feed one encoded frame. Safe to call from the encoder's callback thread.
    public func append(_ accessUnit: AccessUnit) {
        stream.append(accessUnit)
    }

    public func stop() async {
        lock.lock()
        let wasStarted = started
        started = false
        if wasStarted { ended = true }
        lock.unlock()
        await stream.stop()
    }

    public func status() -> MirrorSessionStatus {
        let s = stream.status()
        lock.lock(); defer { lock.unlock() }
        let phase: MirrorSessionPhase
        if failed {
            phase = .failed
        } else if ended {
            phase = .ended
        } else if !started {
            phase = .idle
        } else {
            phase = s.segmentCount > 0 ? .streaming : .waitingForStream
        }
        return MirrorSessionStatus(
            phase: phase,
            streamURL: streamURL,
            port: s.port,
            segmentCount: s.segmentCount,
            lastError: lastError,
            handoffSource: handoffSource,
            target: target,
            quality: quality
        )
    }

    private func resolveTarget(_ handoff: MirrorHandoff?) async -> (MirrorTarget, HandoffSource) {
        guard let handoff else {
            let tvs = await discoveryFallback().filter { $0.type == .chromecast }
            if tvs.count == 1 { return (.cast(tvs[0]), .noHandoff) }
            return (.browserOnly, .noHandoff)
        }
        switch handoff.selection {
        case .device(let device): return (.cast(device), .selectedDevice(id: device.id))
        case .noneSelected: return (.browserOnly, .noneSelected)
        }
    }

    private func debugJSON() -> Data {
        let s = status()
        let object: [String: Any] = [
            "phase": s.phase.rawValue,
            "segmentCount": s.segmentCount,
            "port": Int(s.port),
            "streamURL": s.streamURL ?? NSNull(),
            "lastError": s.lastError ?? NSNull(),
            "handoffSource": s.handoffSource.description
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}