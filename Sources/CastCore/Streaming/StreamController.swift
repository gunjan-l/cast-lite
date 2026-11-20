import Foundation

public actor StreamController {
    public private(set) var isStreaming: Bool = false
    public private(set) var serverPort: UInt16 = 0
    private let server: HTTPServer
    private let patternGenerator: TestPatternGenerator
    private let packetizer: MPEGTSPacketizer
    private let segmenter: HLSSegmenter
    private var hostedMedia: [String: Data] = [:]
    private var liveSegmentTask: Task<Void, Never>?

    public init(port: UInt16 = 8080) {
        self.server = HTTPServer(port: port)
        self.patternGenerator = TestPatternGenerator()
        self.packetizer = MPEGTSPacketizer()
        self.segmenter = HLSSegmenter(targetDuration: 1, windowSize: 10)
    }

    public func setHostedMedia(name: String, data: Data) {
        hostedMedia[name] = data
    }

    public func getSegmentData(name: String) -> Data? {
        return segmenter.getSegment(name: name)
    }

    public func start() async throws -> UInt16 {
        guard !isStreaming else { return serverPort }

        // Populate initial rolling HLS segments
        for i in 0..<5 {
            appendSegment(pts: UInt64(i * 90000))
        }

        // Register sample MP4 media for playback verification
        if hostedMedia["sample.mp4"] == nil {
            hostedMedia["sample.mp4"] = Data(repeating: 0x00, count: 1024)
        }

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

        // Mode 2: Live MJPEG stream endpoint
        let generator = self.patternGenerator
        await server.registerRoute(path: "/stream") { _ in
            let frame = generator.nextFrame(timestamp: 0)
            let formatted = MJPEGStreamFormatter.formatFrame(jpegData: frame.data)
            return HTTPResponse(statusCode: 200, statusText: "OK", headers: MJPEGStreamFormatter.multipartHeader(), body: formatted)
        }

        // Register status API
        await server.registerRoute(path: "/status") { _ in
            return HTTPResponse.ok(
                body: "{\"status\":\"streaming\",\"mode\":\"test-pattern\",\"hls\":\"/stream.m3u8\",\"mjpeg\":\"/stream\"}",
                contentType: "application/json"
            )
        }

        // Register single frame endpoint
        await server.registerRoute(path: "/frame") { _ in
            let frame = generator.nextFrame(timestamp: 0)
            return HTTPResponse.ok(data: frame.data, contentType: frame.contentType)
        }

        // Fallback handler for .ts segments and /media/ byte-range requests
        await server.setFallbackHandler { request in
            let path = request.path.components(separatedBy: "?").first ?? request.path

            // Handle .ts segments directly via thread-safe segmenter
            if path.hasSuffix(".ts") {
                let segmentName = path.components(separatedBy: "/").last ?? path
                if let data = hlsSegmenter.getSegment(name: segmentName) {
                    return HTTPResponse(
                        statusCode: 200,
                        statusText: "OK",
                        headers: [
                            "Content-Type": "video/mp2t",
                            "Content-Length": "\(data.count)",
                            "Cache-Control": "no-cache"
                        ],
                        body: data
                    )
                }
            }

            return HTTPResponse.notFound()
        }

        let boundPort = try await server.start()
        self.serverPort = boundPort
        self.isStreaming = true

        startLiveHLSLoop()
        return boundPort
    }

    private func appendSegment(pts: UInt64) {
        var chunk = packetizer.generatePAT()
        chunk.append(packetizer.generatePMT())
        let nalu = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00])
        for pkt in packetizer.packetizeVideo(nalu: nalu, pts: pts, isKeyframe: true) {
            chunk.append(pkt)
        }
        segmenter.addSegment(data: chunk, duration: 1.0)
    }

    private func startLiveHLSLoop() {
        liveSegmentTask = Task.detached { [weak self] in
            var currentPts: UInt64 = 450000
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self = self else { break }
                let active = await self.isStreaming
                guard active else { break }

                await self.appendSegment(pts: currentPts)
                currentPts += 90000
            }
        }
    }

    public func stop() async {
        guard isStreaming else { return }
        self.isStreaming = false
        liveSegmentTask?.cancel()
        liveSegmentTask = nil
        await server.stop()
        self.serverPort = 0
    }
}
