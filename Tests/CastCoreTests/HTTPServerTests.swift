import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking

extension URLSession {
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: url) { data, response, error in
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

final class HTTPServerTests: XCTestCase {

    func testHTTPRequestParserGetStatus() {
        let raw = "GET /status HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: TestClient\r\n\r\n"
        let request = HTTPRequestParser.parse(data: Data(raw.utf8))

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/status")
        XCTAssertEqual(request?.headers["host"], "localhost:8080")
    }

    func testHTTPRequestParserInvalidData() {
        let raw = "INVALID REQUEST"
        let request = HTTPRequestParser.parse(data: Data(raw.utf8))
        XCTAssertNil(request)
    }

    func testHTTPResponseFormatting() {
        let response = HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: ["Content-Type": "text/plain"],
            body: Data("Hello Cast-Lite".utf8)
        )
        let formattedData = response.serialize()
        let formattedString = String(decoding: formattedData, as: UTF8.self)

        XCTAssertTrue(formattedString.contains("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(formattedString.contains("Content-Type: text/plain\r\n"))
        XCTAssertTrue(formattedString.contains("Content-Length: 15\r\n"))
        XCTAssertTrue(formattedString.contains("Access-Control-Allow-Origin: *\r\n"))
        XCTAssertTrue(formattedString.hasSuffix("\r\n\r\nHello Cast-Lite"))
    }

    func testHTTPServerOptionsPreflightHandling() async throws {
        let server = HTTPServer(port: 0)
        let boundPort = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/stream.m3u8")!)
        request.httpMethod = "OPTIONS"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Response is not HTTPURLResponse")
            return
        }

        XCTAssertEqual(httpResponse.statusCode, 204)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        XCTAssertNotNil(httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Methods"))

        await server.stop()
    }

    func testHTTPServerStartAndHandleStatus() async throws {
        let server = HTTPServer(port: 0) // Port 0 binds to ephemeral port
        let boundPort = try await server.start()
        XCTAssertGreaterThan(boundPort, 0)

        // Register route handler
        await server.registerRoute(path: "/status") { _ in
            return HTTPResponse.ok(body: "{\"status\":\"ok\"}", contentType: "application/json")
        }

        // Execute request to server using URLSession
        let url = URL(string: "http://127.0.0.1:\(boundPort)/status")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Response is not HTTPURLResponse")
            return
        }

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"status\":\"ok\"}")

        await server.stop()
    }

    func testHTTPServerNotFoundRoute() async throws {
        let server = HTTPServer(port: 0)
        let boundPort = try await server.start()

        let url = URL(string: "http://127.0.0.1:\(boundPort)/nonexistent")!
        let (_, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Response is not HTTPURLResponse")
            return
        }

        XCTAssertEqual(httpResponse.statusCode, 404)
        await server.stop()
    }

    func testTestPatternGeneratorGeneratesFrames() {
        let generator = TestPatternGenerator(width: 320, height: 240)
        let frame1 = generator.nextFrame(timestamp: 0.0)
        let frame2 = generator.nextFrame(timestamp: 0.1)

        XCTAssertFalse(frame1.data.isEmpty)
        XCTAssertFalse(frame2.data.isEmpty)
        XCTAssertEqual(frame1.contentType, "image/jpeg")
        XCTAssertEqual(frame1.frameIndex, 0)
        XCTAssertEqual(frame2.frameIndex, 1)
    }

    func testStreamControllerServesViewerAndStatus() async throws {
        let controller = StreamController(port: 0)
        let port = try await controller.start()
        XCTAssertGreaterThan(port, 0)
        let streaming = await controller.isStreaming
        XCTAssertTrue(streaming)

        // Verify HTML viewer
        let viewURL = URL(string: "http://127.0.0.1:\(port)/view")!
        let (viewData, viewResponse) = try await URLSession.shared.data(from: viewURL)
        let viewHTTP = viewResponse as? HTTPURLResponse
        XCTAssertEqual(viewHTTP?.statusCode, 200)
        XCTAssertTrue(String(decoding: viewData, as: UTF8.self).contains("Cast-Lite Live Stream Tracer"))

        // Verify Status
        let statusURL = URL(string: "http://127.0.0.1:\(port)/status")!
        let (statusData, statusResponse) = try await URLSession.shared.data(from: statusURL)
        let statusHTTP = statusResponse as? HTTPURLResponse
        XCTAssertEqual(statusHTTP?.statusCode, 200)
        XCTAssertTrue(String(decoding: statusData, as: UTF8.self).contains("test-pattern"))

        await controller.stop()
        let stoppedStreaming = await controller.isStreaming
        XCTAssertFalse(stoppedStreaming)
    }

    func testStreamControllerServesHostedMediaWithByteRange() async throws {
        let controller = StreamController(port: 0)
        let sampleMedia = Data((0..<200).map { UInt8($0) })
        await controller.setHostedMedia(name: "test_clip.mp4", data: sampleMedia)
        let port = try await controller.start()

        // Test full GET
        let mediaURL = URL(string: "http://127.0.0.1:\(port)/media/test_clip.mp4")!
        let (fullData, fullResponse) = try await URLSession.shared.data(from: mediaURL)
        let fullHTTP = fullResponse as? HTTPURLResponse
        XCTAssertEqual(fullHTTP?.statusCode, 200)
        XCTAssertEqual(fullData.count, 200)

        // Test range request
        var rangeReq = URLRequest(url: mediaURL)
        rangeReq.setValue("bytes=0-49", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeReq)
        let rangeHTTP = rangeResponse as? HTTPURLResponse
        XCTAssertEqual(rangeHTTP?.statusCode, 206)
        XCTAssertEqual(rangeData.count, 50)
        XCTAssertEqual(rangeHTTP?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-49/200")

        await controller.stop()
    }
}
