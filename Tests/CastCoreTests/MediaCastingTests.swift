import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking

extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}
#endif
@testable import CastCore

final class MediaCastingTests: XCTestCase {

    func testByteRangeParserFullRange() {
        let totalSize = 1000
        let rangeHeader = "bytes=0-499"
        let range = ByteRangeParser.parse(header: rangeHeader, totalSize: totalSize)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, 0)
        XCTAssertEqual(range?.end, 499)
        XCTAssertEqual(range?.length, 500)
        XCTAssertEqual(range?.contentRangeHeader(total: totalSize), "bytes 0-499/1000")
    }

    func testByteRangeParserOpenEndedRange() {
        let totalSize = 1000
        let rangeHeader = "bytes=500-"
        let range = ByteRangeParser.parse(header: rangeHeader, totalSize: totalSize)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, 500)
        XCTAssertEqual(range?.end, 999)
        XCTAssertEqual(range?.length, 500)
        XCTAssertEqual(range?.contentRangeHeader(total: totalSize), "bytes 500-999/1000")
    }

    func testByteRangeParserInvalidRange() {
        let totalSize = 1000
        let rangeHeader = "invalid-range"
        let range = ByteRangeParser.parse(header: rangeHeader, totalSize: totalSize)
        XCTAssertNil(range)
    }

    func testUPnPSetAVTransportURISOAPPayload() {
        let mediaURL = "http://192.168.1.50:8080/media/video.mp4"
        let soapPayload = UPnPClient.generateSetAVTransportURIPayload(mediaURL: mediaURL)

        XCTAssertTrue(soapPayload.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        XCTAssertTrue(soapPayload.contains("<CurrentURI>\(mediaURL)</CurrentURI>"))
        XCTAssertTrue(soapPayload.contains("</s:Envelope>"))
    }

    func testUPnPPlayAndStopPayloads() {
        let playPayload = UPnPClient.generatePlayPayload()
        XCTAssertTrue(playPayload.contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        XCTAssertTrue(playPayload.contains("<Speed>1</Speed>"))

        let stopPayload = UPnPClient.generateStopPayload()
        XCTAssertTrue(stopPayload.contains("<u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    }

    func testRokuECPLaunchURL() {
        let mediaURL = "http://192.168.1.50:8080/media/video.mp4"
        let deviceIP = "192.168.1.100"
        let ecpURL = RokuECPClient.buildLaunchURL(deviceIP: deviceIP, mediaURL: mediaURL, format: "mp4")

        XCTAssertEqual(ecpURL.scheme, "http")
        XCTAssertEqual(ecpURL.host, "192.168.1.100")
        XCTAssertEqual(ecpURL.port, 8060)
        XCTAssertTrue(ecpURL.path.contains("/launch/15985"))
        XCTAssertTrue(ecpURL.query?.contains("streamformat=mp4") == true)
    }

    func testHTTPServerServesByteRangePartialContent() async throws {
        let server = HTTPServer(port: 0)
        let boundPort = try await server.start()

        // 100 bytes of dummy test media
        let sampleData = Data((0..<100).map { UInt8($0) })

        await server.registerRoute(path: "/media.mp4") { request in
            if let rangeHeader = request.headers["range"] ?? request.headers["Range"],
               let range = ByteRangeParser.parse(header: rangeHeader, totalSize: sampleData.count) {
                let subdata = sampleData.subdata(in: range.start..<(range.end + 1))
                return HTTPResponse(
                    statusCode: 206,
                    statusText: "Partial Content",
                    headers: [
                        "Content-Type": "video/mp4",
                        "Content-Range": range.contentRangeHeader(total: sampleData.count),
                        "Content-Length": "\(subdata.count)",
                        "Accept-Ranges": "bytes"
                    ],
                    body: subdata
                )
            }
            return HTTPResponse.ok(data: sampleData, contentType: "video/mp4")
        }

        // Test Range request
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/media.mp4")!)
        request.setValue("bytes=10-29", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 206)
        XCTAssertEqual(httpResponse?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-29/100")
        XCTAssertEqual(data.count, 20)

        await server.stop()
    }
}
