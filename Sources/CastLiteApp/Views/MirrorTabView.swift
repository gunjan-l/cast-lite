#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct MirrorTabView: View {
    @State private var isStreaming = false
    @State private var streamURL = ""
    @State private var streamController = StreamController()
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Device connection status banner
                HStack {
                    Circle()
                        .fill(isStreaming ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(isStreaming ? "Streaming Active" : "Ready to Stream")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)

                Spacer()

                // Mirroring Card
                VStack(spacing: 16) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)

                    Text("Universal Screen Mirror")
                        .font(.title2.bold())

                    Text("Mirror your screen to smart TVs, PC, Mac, or open the link below in any browser on the local Wi-Fi.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if isStreaming && !streamURL.isEmpty {
                        VStack(spacing: 8) {
                            Text("Open in any browser:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Text(streamURL)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.blue)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }

                    Button(action: toggleStreaming) {
                        HStack {
                            Image(systemName: isStreaming ? "stop.fill" : "play.fill")
                            Text(isStreaming ? "Stop Test Stream" : "Start Test Stream")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isStreaming ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .navigationTitle("Cast-Lite")
        }
    }

    private func toggleStreaming() {
        Task {
            if isStreaming {
                await streamController.stop()
                await MainActor.run {
                    self.isStreaming = false
                    self.streamURL = ""
                }
            } else {
                do {
                    let port = try await streamController.start()
                    await MainActor.run {
                        self.isStreaming = true
                        self.streamURL = "http://localhost:\(port)/view"
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to start server: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
#endif
