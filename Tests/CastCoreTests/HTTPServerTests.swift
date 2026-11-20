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

    /// Opens a loopback connection and sends only part of a request, so the server
    /// is left waiting for the rest. Caller closes the returned descriptor.
    private func openStalledConnection(port: UInt16) throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        let partial = Array("GET /status HTTP/1.1\r\nHost: x\r\n".utf8)
        _ = send(fd, partial, partial.count, 0)
        return fd
    }

    func testSlowRequestDoesNotDelayConcurrentRequest() async throws {
        let server = HTTPServer(port: 0)
        let port = try await server.start()
        await server.registerRoute(path: "/status") { _ in HTTPResponse.ok(body: "ok", contentType: "text/plain") }

        let stalled = try openStalledConnection(port: port)
        defer { close(stalled) }
        try await Task.sleep(nanoseconds: 200_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        request.timeoutInterval = 2
        let (data, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")

        await server.stop()
    }

    func testStopCompletesWhileSlowRequestIsOpen() async throws {
        let server = HTTPServer(port: 0)
        let port = try await server.start()

        let stalled = try openStalledConnection(port: port)
        defer { close(stalled) }
        try await Task.sleep(nanoseconds: 200_000_000)

        let stopped = expectation(description: "stop returned")
        Task {
            await server.stop()
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 2)
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
}
