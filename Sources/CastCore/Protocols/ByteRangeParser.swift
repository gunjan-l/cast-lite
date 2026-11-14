import Foundation

public struct ByteRange: Sendable, Equatable {
    public let start: Int
    public let end: Int

    public var length: Int {
        return end - start + 1
    }

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contentRangeHeader(total: Int) -> String {
        return "bytes \(start)-\(end)/\(total)"
    }
}

public enum ByteRangeParser {
    public static func parse(header: String, totalSize: Int) -> ByteRange? {
        guard totalSize > 0 else { return nil }

        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }

        let spec = trimmed.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.components(separatedBy: "-")
        guard parts.count == 2 else { return nil }

        let firstPart = parts[0].trimmingCharacters(in: .whitespaces)
        let secondPart = parts[1].trimmingCharacters(in: .whitespaces)

        if let start = Int(firstPart) {
            if let end = Int(secondPart) {
                guard start <= end, start < totalSize else { return nil }
                return ByteRange(start: start, end: min(end, totalSize - 1))
            } else if secondPart.isEmpty {
                guard start < totalSize else { return nil }
                return ByteRange(start: start, end: totalSize - 1)
            }
        } else if firstPart.isEmpty, let suffixLength = Int(secondPart) {
            guard suffixLength > 0 else { return nil }
            let start = max(0, totalSize - suffixLength)
            return ByteRange(start: start, end: totalSize - 1)
        }

        return nil
    }
}
