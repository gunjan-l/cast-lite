import Foundation

public actor StreamController {
    public private(set) var isStreaming: Bool = false
    public private(set) var serverPort: UInt16 = 0
    private let server: HTTPServer
    private let patternGenerator: TestPatternGenerator
    private let packetizer: MPEGTSPacketizer
    private let segmenter: HLSSegmenter

    public init(port: UInt16 = 8080) {
        self.server = HTTPServer(port: port)
        self.patternGenerator = TestPatternGenerator()
        self.packetizer = MPEGTSPacketizer()
        self.segmenter = HLSSegmenter(targetDuration: 1, windowSize: 4)
    }

    public func start() async throws -> UInt16 {
        guard !isStreaming else { return serverPort }

        // Populate initial rolling HLS segment with PAT/PMT and dummy video TS packet
        var initialChunk = packetizer.generatePAT()
        initialChunk.append(packetizer.generatePMT())
        let initialNalu = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E])
        for pkt in packetizer.packetizeVideo(nalu: initialNalu, pts: 0, isKeyframe: true) {
            initialChunk.append(pkt)
        }
        segmenter.addSegment(data: initialChunk, duration: 1.0)

        // Register HTML stream viewer
        let htmlContent = patternGenerator.generateHTMLTestPattern()
        await server.registerRoute(path: "/view") { _ in
            return HTTPResponse.ok(body: htmlContent, contentType: "text/html; charset=utf-8")
        }

        // Register HLS m3u8 playlist endpoint
        let hlsSegmenter = self.segmenter
        await server.registerRoute(path: "/stream.m3u8") { _ in
            let playlist = hlsSegmenter.generatePlaylist()
            return HTTPResponse.ok(body: playlist, contentType: "application/vnd.apple.mpegurl")
        }

        // Register status API
        await server.registerRoute(path: "/status") { _ in
            return HTTPResponse.ok(body: "{\"status\":\"streaming\",\"mode\":\"test-pattern\",\"hls\":\"/stream.m3u8\"}", contentType: "application/json")
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
