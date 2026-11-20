import Foundation

/// Cuts a stream of access units into MPEG-TS HLS segments. A segment closes only when
/// the next keyframe arrives, so every segment starts on an IDR and its duration is the
/// PTS delta between its first keyframe and the next one.
public final class HLSSegmenter: @unchecked Sendable {
    public struct Segment: Sendable {
        public let sequenceNumber: Int
        public let filename: String
        public let duration: Double
        public let data: Data
    }

    public static let defaultWindowSize = 6

    public let windowSize: Int
    private let packetizer = MPEGTSPacketizer()
    private let lock = NSLock()
    private var window: [Segment] = []
    private var completedCount = 0
    private var openData: Data?
    private var openStart: PTS90kHz?

    public init(windowSize: Int = HLSSegmenter.defaultWindowSize) {
        self.windowSize = windowSize
    }

    /// Total segments completed since creation (not just those still in the window).
    public var completedSegmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completedCount
    }

    public func append(_ accessUnit: AccessUnit) {
        lock.lock()
        defer { lock.unlock() }

        if accessUnit.isKeyframe {
            if let data = openData, let start = openStart {
                let seconds = max(0, (accessUnit.pts.ticks - start.ticks)).asSeconds
                let seq = completedCount
                completedCount += 1
                window.append(Segment(sequenceNumber: seq, filename: "segment\(seq).ts", duration: seconds, data: data))
                if window.count > windowSize {
                    window.removeFirst(window.count - windowSize)
                }
            }
            var data = packetizer.generatePAT()
            data.append(packetizer.generatePMT())
            openData = data
            openStart = accessUnit.pts
        }

        // Frames ahead of the first keyframe cannot be decoded; drop them.
        guard openData != nil else { return }
        for packet in packetizer.packetizeVideo(accessUnit) {
            openData?.append(packet)
        }
    }

    /// Nil until the first segment has completed.
    public func playlist() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let first = window.first else { return nil }
        let longest = window.map(\.duration).max() ?? 1
        let target = max(1, Int(longest.rounded(.up)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(first.sequenceNumber)"
        ]
        for seg in window {
            lines.append(String(format: "#EXTINF:%.3f,", seg.duration))
            lines.append(seg.filename)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func segment(named name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return window.first(where: { $0.filename == name })?.data
    }
}

private extension Int64 {
    var asSeconds: Double { Double(self) / Double(PTS90kHz.ticksPerSecond) }
}
