import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let statusText: String
    public var headers: [String: String]
    public let body: Data

    public init(statusCode: Int, statusText: String, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    public static func ok(body: String, contentType: String = "text/plain") -> HTTPResponse {
        let bodyData = Data(body.utf8)
        return HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [
                "Content-Type": contentType,
                "Content-Length": "\(bodyData.count)"
            ],
            body: bodyData
        )
    }

    public static func ok(data: Data, contentType: String) -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [
                "Content-Type": contentType,
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    public static func notFound() -> HTTPResponse {
        let body = Data("404 Not Found".utf8)
        return HTTPResponse(
            statusCode: 404,
            statusText: "Not Found",
            headers: [
                "Content-Type": "text/plain",
                "Content-Length": "\(body.count)"
            ],
            body: body
        )
    }

    public func serialize() -> Data {
        var headerLines = ["HTTP/1.1 \(statusCode) \(statusText)"]
        var finalHeaders = headers
        if finalHeaders["Content-Length"] == nil && finalHeaders["content-length"] == nil {
            finalHeaders["Content-Length"] = "\(body.count)"
        }
        if finalHeaders["Connection"] == nil && finalHeaders["connection"] == nil {
            finalHeaders["Connection"] = "close"
        }
        if finalHeaders["Access-Control-Allow-Origin"] == nil && finalHeaders["access-control-allow-origin"] == nil {
            finalHeaders["Access-Control-Allow-Origin"] = "*"
        }
        for (k, v) in finalHeaders {
            headerLines.append("\(k): \(v)")
        }
        let headerData = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        var fullData = headerData
        fullData.append(body)
        return fullData
    }
}
