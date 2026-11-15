import Foundation

public actor StreamController {
    public private(set) var isStreaming: Bool = false
    public private(set) var serverPort: UInt16 = 0
    private let server: HTTPServer
    private let ipcServer: IPCServer
    private let patternGenerator: TestPatternGenerator
    private let packetizer: MPEGTSPacketizer
    private let segmenter: HLSSegmenter
    private var hostedMedia: [String: Data] = [:]
    private var liveSegmentTask: Task<Void, Never>?

    // Standard H.264 Baseline Profile SPS (640x360) and PPS
    public static let defaultSPS = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x1E,
        0xD9, 0x00, 0xA0, 0x0B, 0x77, 0x90
    ])
    public static let defaultPPS = Data([
        0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80
    ])
    public static let defaultIDR = Data([
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00,
        0x10, 0xFF, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x03, 0x00, 0x00, 0x7F
    ])

    public init(port: UInt16 = 8080) {
        self.server = HTTPServer(port: port)
        self.ipcServer = IPCServer()
        self.patternGenerator = TestPatternGenerator()
        self.packetizer = MPEGTSPacketizer()
        self.segmenter = HLSSegmenter(targetDuration: 1, windowSize: 10)
    }

    public func setHostedMedia(name: String, data: Data) {
        hostedMedia[name] = data
    }

    public func getHostedMedia(name: String) -> Data? {
        if let data = hostedMedia[name] {
            return data
        }
        if name.hasSuffix(".mp4") || name.hasSuffix(".MOV") {
            return hostedMedia["sample.mp4"]
        }
        return nil
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
        await server.setFallbackHandler { [weak self] request in
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
                            "Cache-Control": "no-cache",
                            "Access-Control-Allow-Origin": "*"
                        ],
                        body: data
                    )
                }
            }

            // Handle /media/ byte-range requests
            if path.contains("/media/") {
                let mediaName = path.components(separatedBy: "/media/").last ?? path
                if let self = self, let data = await self.getHostedMedia(name: mediaName) {
                    if let rangeHeader = request.headers["range"] ?? request.headers["Range"],
                       let range = ByteRangeParser.parse(header: rangeHeader, totalSize: data.count) {
                        let subdata = data.subdata(in: range.start..<(range.end + 1))
                        return HTTPResponse(
                            statusCode: 206,
                            statusText: "Partial Content",
                            headers: [
                                "Content-Type": "video/mp4",
                                "Content-Range": range.contentRangeHeader(total: data.count),
                                "Content-Length": "\(subdata.count)",
                                "Accept-Ranges": "bytes",
                                "Access-Control-Allow-Origin": "*"
                            ],
                            body: subdata
                        )
                    }
                    return HTTPResponse.ok(data: data, contentType: "video/mp4")
                }
            }

            return HTTPResponse.notFound()
        }

        let boundPort = try await server.start()
        self.serverPort = boundPort
        self.isStreaming = true

        // Start IPC server to receive live screen frames from Broadcast Extension
        do {
            _ = try await ipcServer.start(port: 8999)
            await ipcServer.setOnPacketReceived { [weak self] packet in
                Task { [weak self] in
                    await self?.handleIncomingIPCPacket(packet)
                }
            }
        } catch {
            // IPC bind error handled gracefully
        }

        startLiveHLSLoop()
        return boundPort
    }

    public func handleIncomingIPCPacket(_ packet: IPCPacket) {
        guard isStreaming else { return }
        if packet.type == .video && !packet.payload.isEmpty {
            var chunk = packetizer.generatePAT()
            chunk.append(packetizer.generatePMT())
            var finalNalu = Data()
            if packet.isKeyframe {
                finalNalu.append(Self.defaultSPS)
                finalNalu.append(Self.defaultPPS)
            }
            finalNalu.append(packet.payload)
            for pkt in packetizer.packetizeVideo(nalu: finalNalu, pts: packet.timestamp, isKeyframe: packet.isKeyframe) {
                chunk.append(pkt)
            }
            segmenter.addSegment(data: chunk, duration: 1.0)
        }
    }

    private func appendSegment(pts: UInt64) {
        var chunk = packetizer.generatePAT()
        chunk.append(packetizer.generatePMT())
        var nalu = Self.defaultSPS
        nalu.append(Self.defaultPPS)
        nalu.append(Self.defaultIDR)
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
        await ipcServer.stop()
        await server.stop()
        self.serverPort = 0
    }
}
