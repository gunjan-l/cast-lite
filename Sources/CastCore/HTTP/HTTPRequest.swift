import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HTTPRequestParser {
    public static func parse(data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        guard let headerPart = parts.first, !headerPart.isEmpty else {
            return nil
        }

        let lines = headerPart.components(separatedBy: "\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestTokens = requestLine.split(separator: " ").map(String.init)
        guard requestTokens.count == 3, requestTokens[2].uppercased().hasPrefix("HTTP/") else {
            return nil
        }

        let method = requestTokens[0].uppercased()
        let fullPath = requestTokens[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyData: Data
        if parts.count > 1 {
            bodyData = Data(parts[1...].joined(separator: "\n\n").utf8)
        } else {
            bodyData = Data()
        }

        return HTTPRequest(method: method, path: fullPath, headers: headers, body: bodyData)
    }
}
