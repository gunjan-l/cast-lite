import Foundation

public struct VideoFrame: Sendable {
    public let data: Data
    public let contentType: String
    public let frameIndex: Int
    public let timestamp: Double

    public init(data: Data, contentType: String = "image/jpeg", frameIndex: Int, timestamp: Double) {
        self.data = data
        self.contentType = contentType
        self.frameIndex = frameIndex
        self.timestamp = timestamp
    }
}

public final class TestPatternGenerator: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private var currentIndex: Int = 0
    private let lock = NSLock()

    // Minimal valid JPEG binary (1x1 red pixel)
    private static let sampleJPEGData: Data = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48,
        0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x03, 0x02, 0x02, 0x03, 0x02, 0x02, 0x03,
        0x03, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04, 0x05, 0x08, 0x05, 0x05, 0x04, 0x04, 0x05, 0x0A, 0x07,
        0x07, 0x06, 0x08, 0x0C, 0x0A, 0x0C, 0x0C, 0x0B, 0x0A, 0x0B, 0x0B, 0x0D, 0x0E, 0x12, 0x10, 0x0D,
        0x0E, 0x11, 0x0E, 0x0B, 0x0B, 0x10, 0x16, 0x10, 0x11, 0x13, 0x14, 0x15, 0x15, 0x15, 0x0C, 0x0F,
        0x17, 0x18, 0x16, 0x14, 0x18, 0x12, 0x14, 0x15, 0x14, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
        0x00, 0xBF, 0xFF, 0xD9
    ])

    public init(width: Int = 640, height: Int = 480) {
        self.width = width
        self.height = height
    }

    public func nextFrame(timestamp: Double) -> VideoFrame {
        lock.lock()
        defer { lock.unlock() }

        let index = currentIndex
        currentIndex += 1
        return VideoFrame(
            data: Self.sampleJPEGData,
            contentType: "image/jpeg",
            frameIndex: index,
            timestamp: timestamp
        )
    }

    public func generateHTMLTestPattern() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Cast-Lite Live Stream</title>
            <style>
                body { background: #121212; color: #fff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
                .card { background: #1e1e1e; padding: 24px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.5); text-align: center; }
                canvas { border-radius: 8px; border: 2px solid #007aff; }
                h1 { margin-top: 0; font-size: 20px; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Cast-Lite Live Stream Tracer</h1>
                <canvas id="view" width="320" height="240"></canvas>
                <p id="stats">Active Stream</p>
            </div>
            <script>
                const canvas = document.getElementById('view');
                const ctx = canvas.getContext('2d');
                let frame = 0;
                function draw() {
                    frame++;
                    ctx.fillStyle = '#0a0a0a';
                    ctx.fillRect(0, 0, canvas.width, canvas.height);
                    ctx.fillStyle = '#007aff';
                    const x = (Math.sin(frame * 0.05) + 1) * 0.5 * (canvas.width - 40);
                    ctx.fillRect(x, 100, 40, 40);
                    ctx.fillStyle = '#ffffff';
                    ctx.font = '14px monospace';
                    ctx.fillText('Frame: ' + frame, 10, 20);
                    requestAnimationFrame(draw);
                }
                draw();
            </script>
        </body>
        </html>
        """
    }
}
