import Foundation

public actor StreamController {
    public private(set) var isStreaming: Bool = false
    public private(set) var serverPort: UInt16 = 0
    private let server: HTTPServer
    private let patternGenerator: TestPatternGenerator

    public init(port: UInt16 = 8080) {
        self.server = HTTPServer(port: port)
        self.patternGenerator = TestPatternGenerator()
    }

    public func start() async throws -> UInt16 {
        guard !isStreaming else { return serverPort }

        // Register HTML stream viewer
        let htmlContent = patternGenerator.generateHTMLTestPattern()
        await server.registerRoute(path: "/view") { _ in
            return HTTPResponse.ok(body: htmlContent, contentType: "text/html; charset=utf-8")
        }

        // Register status API
        await server.registerRoute(path: "/status") { _ in
            return HTTPResponse.ok(body: "{\"status\":\"streaming\",\"mode\":\"test-pattern\"}", contentType: "application/json")
        }

        // Register single frame endpoint
        let generator = self.patternGenerator
        await server.registerRoute(path: "/frame") { _ in
            let frame = generator.nextFrame(timestamp: 0)
            return HTTPResponse.ok(data: frame.data, contentType: frame.contentType)
        }

        let boundPort = try await server.start()
        self.serverPort = boundPort
        self.isStreaming = true
        return boundPort
    }

    public func stop() async {
        guard isStreaming else { return }
        await server.stop()
        self.isStreaming = false
        self.serverPort = 0
    }
}
