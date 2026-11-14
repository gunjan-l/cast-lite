import Foundation

public final class HLSSegmenter: @unchecked Sendable {
    public struct Segment: Sendable {
        public let sequenceNumber: Int
        public let filename: String
        public let duration: Double
        public let data: Data
    }

    public let targetDuration: Int
    public let windowSize: Int
    private var segments: [Segment] = []
    private var currentSequence: Int = 0
    private let lock = NSLock()

    public init(targetDuration: Int = 1, windowSize: Int = 3) {
        self.targetDuration = targetDuration
        self.windowSize = windowSize
    }

    public func addSegment(data: Data, duration: Double) {
        lock.lock()
        defer { lock.unlock() }

        let seq = currentSequence
        currentSequence += 1
        let filename = "segment\(seq).ts"
        let newSegment = Segment(sequenceNumber: seq, filename: filename, duration: duration, data: data)
        segments.append(newSegment)

        if segments.count > windowSize {
            segments.removeFirst(segments.count - windowSize)
        }
    }

    public func generatePlaylist() -> String {
        lock.lock()
        defer { lock.unlock() }

        let mediaSequence = segments.first?.sequenceNumber ?? 0
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)"
        ]

        for seg in segments {
            lines.append(String(format: "#EXTINF:%.1f,", seg.duration))
            lines.append(seg.filename)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func getSegment(name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return segments.first(where: { $0.filename == name })?.data
    }
}
