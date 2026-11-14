#if canImport(SwiftUI)
import SwiftUI
import CastCore
#if canImport(WebKit)
import WebKit
#endif

public struct WebBrowserView: View {
    @State private var urlString: String = "https://www.w3schools.com/html/html5_video.asp"
    @State private var currentURL: URL?
    @State private var detectedVideo: DetectedWebVideo?
    @State private var isCasting = false
    public var onCastVideo: (DetectedWebVideo) -> Void

    public init(onCastVideo: @escaping (DetectedWebVideo) -> Void = { _ in }) {
        self.onCastVideo = onCastVideo
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.secondary)
                    .font(.caption)

                TextField("Enter website URL...", text: $urlString)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                Button(action: loadURL) {
                    Text("Go")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            ZStack(alignment: .bottom) {
                #if canImport(WebKit) && canImport(UIKit)
                NativeWebViewRepresentable(
                    url: currentURL ?? URL(string: urlString)!,
                    onVideoDetected: { video in
                        withAnimation {
                            self.detectedVideo = video
                        }
                    }
                )
                #else
                VStack(spacing: 16) {
                    Image(systemName: "safari")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)

                    Text("In-App Web Browser")
                        .font(.title3.bold())

                    Text("Detects HTML5 videos on websites automatically.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button("Simulate Video Detection") {
                        withAnimation {
                            self.detectedVideo = DetectedWebVideo(
                                title: "Sample HTML5 Video",
                                url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                                format: .mp4
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6))
                #endif

                // Floating Cast Video banner
                if let video = detectedVideo {
                    HStack(spacing: 12) {
                        Image(systemName: "tv.badge.wifi")
                            .font(.title2)
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video Detected")
                                .font(.caption.bold())
                                .foregroundColor(.white.opacity(0.8))
                            Text(video.title)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button(action: {
                            onCastVideo(video)
                            isCasting = true
                        }) {
                            Text(isCasting ? "Casting..." : "Cast to TV")
                                .fontWeight(.bold)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .foregroundColor(.blue)
                                .cornerRadius(20)
                        }
                    }
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(16)
                    .shadow(radius: 8)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func loadURL() {
        var formatted = urlString.trimmingCharacters(in: .whitespaces)
        if !formatted.lowercased().hasPrefix("http://") && !formatted.lowercased().hasPrefix("https://") {
            formatted = "https://" + formatted
        }
        if let target = URL(string: formatted) {
            currentURL = target
        }
    }
}

#if canImport(WebKit) && canImport(UIKit)
public struct NativeWebViewRepresentable: UIViewRepresentable {
    public let url: URL
    public let onVideoDetected: (DetectedWebVideo) -> Void

    public init(url: URL, onVideoDetected: @escaping (DetectedWebVideo) -> Void) {
        self.url = url
        self.onVideoDetected = onVideoDetected
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onVideoDetected: onVideoDetected)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let scriptSource = WebVideoDetector.snifferUserScript()
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        contentController.add(context.coordinator, name: "videoDetector")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKScriptMessageHandler {
        private let detector = WebVideoDetector()
        private let onVideoDetected: (DetectedWebVideo) -> Void

        public init(onVideoDetected: @escaping (DetectedWebVideo) -> Void) {
            self.onVideoDetected = onVideoDetected
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "videoDetector",
                  let body = message.body as? [String: Any],
                  let detected = detector.processMessage(body: body) else {
                return
            }
            DispatchQueue.main.async {
                self.onVideoDetected(detected)
            }
        }
    }
}
#endif
#endif
