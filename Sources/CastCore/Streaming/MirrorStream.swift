import Foundation

public enum MirrorStreamPhase: String, Sendable {
    case idle
    case waitingForStream = "waiting-for-stream"
    case streaming
    case stopped
}

public struct MirrorStreamStatus: Sendable, Equatable {
    public let phase: MirrorStreamPhase
    /// Bound HTTP port; 0 while not running.
    public let port: UInt16
    /// Segments completed since start (not just those still in the playlist window).
    public let segmentCount: Int
}

/// Turns Annex-B access units into a playable HLS stream served over HTTP:
/// `/view`, `/hls.js`, `/stream.m3u8`, `segmentN.ts` and `/debug`.
public final class MirrorStream: @unchecked Sendable {
    private let server: HTTPServer
    private let segmenter: HLSSegmenter
    private let lock = NSLock()
    private var running = false
    private var stopped = false
    private var boundPort: UInt16 = 0
    private var debugProvider: (@Sendable () -> Data)?

    public init(port: UInt16 = 8080, windowSize: Int = HLSSegmenter.defaultWindowSize) {
        self.server = HTTPServer(port: port)
        self.segmenter = HLSSegmenter(windowSize: windowSize)
    }

    /// Replaces the body of /debug. The owner of the stream (e.g. MirrorSession) supplies richer JSON.
    public func setDebugProvider(_ provider: (@Sendable () -> Data)?) {
        lock.lock(); debugProvider = provider; lock.unlock()
    }

    public var isStreaming: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Starts the HTTP server and returns the bound port.
    public func start() async throws -> UInt16 {
        if let existing = currentPortIfRunning() { return existing }

        let segmenter = self.segmenter
        let owner = self

        await server.registerRoute(path: "/view") { _ in
            HTTPResponse.ok(body: MirrorViewerPage.html, contentType: "text/html; charset=utf-8")
        }
        await server.registerRoute(path: "/hls.js") { _ in
            HTTPResponse.ok(data: MirrorViewerPage.hlsJS, contentType: "application/javascript; charset=utf-8")
        }
        await server.registerRoute(path: "/stream.m3u8") { _ in
            guard let playlist = segmenter.playlist() else { return HTTPResponse.notFound() }
            return HTTPResponse(
                statusCode: 200,
                statusText: "OK",
                headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-cache"],
                body: Data(playlist.utf8)
            )
        }
        await server.registerRoute(path: "/debug") { _ in
            if let custom = owner.currentDebugProvider() {
                return HTTPResponse.ok(data: custom(), contentType: "application/json")
            }
            let s = owner.status()
            let json = "{\"phase\":\"\(s.phase.rawValue)\",\"segmentCount\":\(s.segmentCount),\"port\":\(s.port)}"
            return HTTPResponse.ok(body: json, contentType: "application/json")
        }
        await server.setFallbackHandler { request in
            let path = request.path.components(separatedBy: "?").first ?? request.path
            guard path.hasSuffix(".ts"),
                  let name = path.components(separatedBy: "/").last,
                  let data = segmenter.segment(named: name) else {
                return HTTPResponse.notFound()
            }
            return HTTPResponse(
                statusCode: 200,
                statusText: "OK",
                headers: ["Content-Type": "video/mp2t", "Content-Length": "\(data.count)", "Cache-Control": "no-cache"],
                body: data
            )
        }

        let port = try await server.start()
        lock.lock()
        boundPort = port
        running = true
        stopped = false
        lock.unlock()
        return port
    }

    /// Feed one encoded frame. Safe to call from the encoder's callback thread.
    public func append(_ accessUnit: AccessUnit) {
        segmenter.append(accessUnit)
    }

    public func stop() async {
        lock.lock()
        let wasRunning = running
        running = false
        stopped = true
        boundPort = 0
        lock.unlock()
        guard wasRunning else { return }
        await server.stop()
    }

    public func status() -> MirrorStreamStatus {
        let count = segmenter.completedSegmentCount
        lock.lock(); defer { lock.unlock() }
        let phase: MirrorStreamPhase
        if running {
            phase = count > 0 ? .streaming : .waitingForStream
        } else {
            phase = stopped ? .stopped : .idle
        }
        return MirrorStreamStatus(phase: phase, port: boundPort, segmentCount: count)
    }

    fileprivate func currentDebugProvider() -> (@Sendable () -> Data)? {
        lock.lock(); defer { lock.unlock() }
        return debugProvider
    }

    private func currentPortIfRunning() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        return running ? boundPort : nil
    }
}

enum MirrorViewerPage {
    static let hlsJS: Data = {
        let source = BundledHLSJS.source
        return Data(bytes: source.utf8Start, count: source.utf8CodeUnitCount)
    }()

    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Cast-Lite Mirror</title>
    <style>
    html, body { margin: 0; height: 100%; background: #000; color: #ccc; font-family: -apple-system, system-ui, sans-serif; }
    video { width: 100%; height: 100%; background: #000; display: none; }
    #status { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; font-size: 1.2rem; }
    </style>
    </head>
    <body>
    <div id="status">Waiting for stream...</div>
    <video id="v" controls autoplay muted playsinline></video>
    <script src="/hls.js"></script>
    <script>
    (function () {
      var src = "/stream.m3u8";
      var video = document.getElementById("v");
      var status = document.getElementById("status");
      function show() { status.style.display = "none"; video.style.display = "block"; }
      function waitThenStart() {
        fetch(src, { cache: "no-store" }).then(function (r) {
          if (r.ok) { start(); } else { setTimeout(waitThenStart, 1000); }
        }).catch(function () { setTimeout(waitThenStart, 1000); });
      }
      function start() {
        if (window.Hls && Hls.isSupported()) {
          var hls = new Hls({ liveSyncDurationCount: 3 });
          hls.loadSource(src);
          hls.attachMedia(video);
          hls.on(Hls.Events.MANIFEST_PARSED, function () { show(); video.play(); });
        } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
          video.src = src;
          video.addEventListener("loadedmetadata", function () { show(); video.play(); });
        } else {
          status.textContent = "This browser cannot play HLS.";
        }
      }
      waitThenStart();
    })();
    </script>
    </body>
    </html>
    """
}
