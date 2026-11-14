import Foundation

public enum WebVideoFormat: String, Sendable, Equatable {
    case mp4
    case hls
    case webm
    case other
}

public struct DetectedWebVideo: Identifiable, Sendable, Equatable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let format: WebVideoFormat

    public init(title: String, url: URL, format: WebVideoFormat) {
        self.title = title
        self.url = url
        self.format = format
    }
}

public final class WebVideoDetector: Sendable {

    private static let validExtensions = [".mp4", ".m3u8", ".webm", ".mov", ".m4v", ".mpd"]

    public init() {}

    public static func isValidStreamURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard scheme == "http" || scheme == "https" else {
            return false
        }

        let cleanPath = url.path.lowercased()
        for ext in validExtensions {
            if cleanPath.contains(ext) {
                return true
            }
        }
        return false
    }

    public static func detectFormat(from url: URL) -> WebVideoFormat {
        let path = url.path.lowercased()
        if path.contains(".mp4") || path.contains(".m4v") || path.contains(".mov") {
            return .mp4
        } else if path.contains(".m3u8") {
            return .hls
        } else if path.contains(".webm") {
            return .webm
        } else {
            return .other
        }
    }

    public static func snifferUserScript() -> String {
        return """
        (function() {
            if (window.__castLiteInjected) return;
            window.__castLiteInjected = true;

            function notifyNative(src) {
                if (!src || src.startsWith('blob:') || src.startsWith('data:')) return;
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoDetector) {
                        window.webkit.messageHandlers.videoDetector.postMessage({
                            url: src,
                            title: document.title || 'Web Video'
                        });
                    }
                } catch(e) {}
            }

            function inspectVideo(video) {
                if (video.currentSrc) notifyNative(video.currentSrc);
                else if (video.src) notifyNative(video.src);

                var sources = video.getElementsByTagName('source');
                for (var i = 0; i < sources.length; i++) {
                    if (sources[i].src) notifyNative(sources[i].src);
                }
            }

            var observer = new MutationObserver(function(mutations) {
                mutations.forEach(function(mutation) {
                    mutation.addedNodes.forEach(function(node) {
                        if (node.tagName === 'VIDEO') {
                            inspectVideo(node);
                        } else if (node.querySelectorAll) {
                            var videos = node.querySelectorAll('video');
                            videos.forEach(inspectVideo);
                        }
                    });
                });
            });

            observer.observe(document.documentElement, { childList: true, subtree: true });

            // Hook HTMLMediaElement prototype
            if (window.HTMLMediaElement) {
                var originalPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function() {
                    inspectVideo(this);
                    return originalPlay.apply(this, arguments);
                };
            }

            // Initial scan of existing videos
            document.querySelectorAll('video').forEach(inspectVideo);
        })();
        """
    }

    public func processMessage(body: [String: Any]) -> DetectedWebVideo? {
        guard let urlString = body["url"] as? String,
              Self.isValidStreamURL(urlString),
              let url = URL(string: urlString) else {
            return nil
        }

        let title = (body["title"] as? String) ?? "Web Video"
        let format = Self.detectFormat(from: url)
        return DetectedWebVideo(title: title, url: url, format: format)
    }
}
