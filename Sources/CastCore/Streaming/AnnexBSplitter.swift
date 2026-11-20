import Foundation

/// Splits an Annex-B H.264 elementary stream into access units and stamps each with a
/// constant-frame-rate 90 kHz PTS. Assumes no B-frames, so decode order equals display order.
public enum AnnexBSplitter {
    /// - Parameters:
    ///   - stream: start-code delimited H.264 bytes.
    ///   - framesPerSecond: constant frame rate used to derive PTS.
    public static func accessUnits(from stream: Data, framesPerSecond: Double) -> [AccessUnit] {
        let bytes = [UInt8](stream)
        let starts = startCodeOffsets(bytes)
        guard !starts.isEmpty else { return [] }

        var units: [(range: Range<Int>, keyframe: Bool)] = []
        var unitStart = starts[0].offset
        var hasVCL = false
        var keyframe = false

        for start in starts {
            let payload = start.offset + start.length
            guard payload < bytes.count else { continue }
            let type = Int(bytes[payload] & 0x1F)
            let isVCL = type == 1 || type == 5
            // A new access unit starts at a non-VCL header NAL after a slice, or at a slice with first_mb_in_slice == 0.
            let firstSlice = isVCL && payload + 1 < bytes.count && (bytes[payload + 1] & 0x80) != 0
            let startsNew = hasVCL && ((!isVCL && (6...9).contains(type)) || firstSlice)
            if startsNew {
                units.append((unitStart..<start.offset, keyframe))
                unitStart = start.offset
                hasVCL = false
                keyframe = false
            }
            if isVCL { hasVCL = true }
            if type == 5 { keyframe = true }
        }
        if hasVCL { units.append((unitStart..<bytes.count, keyframe)) }

        return units.enumerated().map { index, unit in
            AccessUnit(
                annexB: Data(bytes[unit.range]),
                pts: PTS90kHz(ticks: Int64((Double(index) * Double(PTS90kHz.ticksPerSecond) / framesPerSecond).rounded())),
                isKeyframe: unit.keyframe
            )
        }
    }

    private static func startCodeOffsets(_ b: [UInt8]) -> [(offset: Int, length: Int)] {
        var result: [(Int, Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if i > 0, b[i - 1] == 0 { result.append((i - 1, 4)) } else { result.append((i, 3)) }
                i += 3
            } else {
                i += 1
            }
        }
        return result
    }
}
