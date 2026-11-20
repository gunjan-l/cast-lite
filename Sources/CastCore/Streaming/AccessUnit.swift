import Foundation

/// A presentation timestamp in 90 kHz ticks, the MPEG-TS clock. A distinct type so
/// microseconds, seconds and ticks cannot be mixed up.
public struct PTS90kHz: Hashable, Comparable, Sendable {
    public static let ticksPerSecond: Int64 = 90_000

    public let ticks: Int64

    public init(ticks: Int64) {
        self.ticks = ticks
    }

    public init(seconds: Double) {
        self.ticks = Int64((seconds * Double(Self.ticksPerSecond)).rounded())
    }

    public var seconds: Double {
        Double(ticks) / Double(Self.ticksPerSecond)
    }

    public static func < (lhs: PTS90kHz, rhs: PTS90kHz) -> Bool {
        lhs.ticks < rhs.ticks
    }
}

/// One encoded H.264 frame in Annex-B form (start-code delimited NAL units).
/// Keyframes are expected to carry SPS and PPS ahead of the IDR slice.
public struct AccessUnit: Sendable {
    public let annexB: Data
    public let pts: PTS90kHz
    public let isKeyframe: Bool

    public init(annexB: Data, pts: PTS90kHz, isKeyframe: Bool) {
        self.annexB = annexB
        self.pts = pts
        self.isKeyframe = isKeyframe
    }
}
