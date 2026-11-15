#if canImport(SwiftUI)
import SwiftUI
import CastCore
#if canImport(PhotosUI)
import PhotosUI
#endif

public struct CastTabView: View {
    @ObservedObject public var appState: CastAppState
    @State private var selectedSegment = 0
    @State private var selectedMediaName: String?
    @State private var showPaywallModal = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    public init(appState: CastAppState = CastAppState()) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header displaying the centrally selected device
                HStack {
                    Image(systemName: appState.selectedDevice?.type.systemIcon ?? "tv")
                        .foregroundColor(.blue)
                    Text("Target TV: \(appState.selectedDevice?.name ?? "No TV Selected")")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Circle()
                        .fill(appState.selectedDevice != nil ? Color.blue : Color.gray)
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal)
                .padding(.top, 4)

                // Error banner (matching MirrorTabView style)
                if let error = appState.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                Picker("Media Source", selection: $selectedSegment) {
                    Text("Camera Roll").tag(0)
                    Text("Web Browser").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedSegment == 0 {
                    cameraRollView
                } else {
                    WebBrowserView { detectedVideo in
                        requestCastMedia(name: detectedVideo.title, streamURL: detectedVideo.url.absoluteString)
                    }
                }

                Spacer()

                // Remote Control Overlay when media is selected/playing
                if selectedMediaName != nil || appState.isPlaying || appState.connectionState == .streaming {
                    remoteControlBar
                }
            }
            .navigationTitle("Cast Media")
            .sheet(isPresented: $showPaywallModal) {
                PaywallModal(isPresented: $showPaywallModal, subscriptionManager: appState.subscriptionManager)
            }
        }
    }

    private var cameraRollView: some View {
        VStack(spacing: 20) {
            #if canImport(PhotosUI)
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)

                    Text("Select Photos or Videos")
                        .font(.headline)

                    Text("Stream personal memories directly in full 4K resolution.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(Color(.systemGray6))
                .cornerRadius(16)
                .padding(.horizontal)
            }
            .onChange(of: selectedPhotoItem) { newItem in
                if newItem != nil {
                    requestCastMedia(name: "IMG_4920.MOV")
                }
            }
            #else
            // Fallback grid on non-Apple platforms
            VStack(spacing: 12) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text("Camera Roll Grid")
                    .font(.headline)

                Button("Simulate Cast Video") {
                    requestCastMedia(name: "Sample_Video_4K.mp4")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            #endif

            // Media grid placeholder
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(1...6, id: \.self) { idx in
                    Button(action: {
                        requestCastMedia(name: "Video_\(idx).mp4")
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemGray5))
                                .aspectRatio(1.0, contentMode: .fit)

                            VStack {
                                Image(systemName: idx % 2 == 0 ? "video.fill" : "photo.fill")
                                    .foregroundColor(.secondary)
                                Text("Item \(idx)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func requestCastMedia(name: String, streamURL: String? = nil) {
        Task {
            let entitled = await appState.subscriptionManager.isEntitled
            if entitled {
                let targetURL: String
                if let streamURL = streamURL {
                    targetURL = streamURL
                } else {
                    let (resolvedURL, _) = appState.networkHelper.resolveStreamURL(port: 8080, path: "media/\(name)")
                    targetURL = resolvedURL
                }
                do {
                    try await appState.castMedia(name: name, url: targetURL)
                    self.selectedMediaName = name
                } catch {
                    self.appState.errorMessage = error.localizedDescription
                }
            } else {
                self.showPaywallModal = true
            }
        }
    }

    private var remoteControlBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "tv.fill")
                    .foregroundColor(.blue)
                Text("Now Casting: \(selectedMediaName ?? appState.selectedDevice?.name ?? "Media")")
                    .font(.subheadline.bold())
                Spacer()
                Button(action: stopPlayback) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }

            // Seek slider
            HStack {
                Text(formatSeconds(appState.playbackPosition))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { appState.playbackPosition },
                        set: { newPos in
                            appState.playbackPosition = newPos
                        }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing {
                            appState.seek(seconds: appState.playbackPosition)
                        }
                    }
                )
                Text("1:40")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Volume control
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { appState.currentVolume },
                        set: { newVol in
                            appState.setVolume(sliderValue: newVol)
                        }
                    ),
                    in: 0...100
                )
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Playback controls
            HStack(spacing: 40) {
                Button(action: {
                    let target = max(0, appState.playbackPosition - 10)
                    appState.seek(seconds: target)
                }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }

                Button(action: {
                    appState.togglePlayPause()
                }) {
                    Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
                }

                Button(action: {
                    let target = min(100, appState.playbackPosition + 10)
                    appState.seek(seconds: target)
                }) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
            }
            .padding(.bottom, 8)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func stopPlayback() {
        selectedMediaName = nil
        appState.stopPlayback()
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
#endif
