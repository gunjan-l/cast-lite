#if canImport(SwiftUI)
import SwiftUI
import CastCore
#if canImport(PhotosUI)
import PhotosUI
#endif

public struct CastTabView: View {
    @State private var selectedSegment = 0
    @State private var castCoordinator = CastSessionCoordinator()
    @State private var isPlaying = false
    @State private var playbackPosition: Double = 0.0
    @State private var selectedMediaName: String?
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Media Source", selection: $selectedSegment) {
                    Text("Camera Roll").tag(0)
                    Text("Web Browser").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedSegment == 0 {
                    cameraRollView
                } else {
                    webCasterPlaceholderView
                }

                Spacer()

                // Remote Control Overlay when media is selected/playing
                if selectedMediaName != nil {
                    remoteControlBar
                }
            }
            .navigationTitle("Cast Media")
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
                    selectedMediaName = "IMG_4920.MOV"
                    isPlaying = true
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
                    selectedMediaName = "Sample_Video_4K.mp4"
                    isPlaying = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            #endif

            // Media grid placeholder
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(1...6, id: \.self) { idx in
                    Button(action: {
                        selectedMediaName = "Video_\(idx).mp4"
                        isPlaying = true
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

    private var webCasterPlaceholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Web Video Caster")
                .font(.headline)
            Text("Browse video websites and cast HTML5 videos directly with one tap.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, 40)
    }

    private var remoteControlBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "tv.fill")
                    .foregroundColor(.blue)
                Text("Now Casting: \(selectedMediaName ?? "")")
                    .font(.subheadline.bold())
                Spacer()
                Button(action: stopPlayback) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }

            // Seek slider
            HStack {
                Text("0:00")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: $playbackPosition, in: 0...100, onEditingChanged: { editing in
                    if !editing {
                        seekTo(seconds: playbackPosition)
                    }
                })
                Text("1:40")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Playback controls
            HStack(spacing: 40) {
                Button(action: { seekTo(seconds: max(0, playbackPosition - 10)) }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }

                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
                }

                Button(action: { seekTo(seconds: min(100, playbackPosition + 10)) }) {
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

    private func togglePlayPause() {
        isPlaying.toggle()
        Task {
            if isPlaying {
                try? await castCoordinator.play()
            } else {
                try? await castCoordinator.pause()
            }
        }
    }

    private func seekTo(seconds: Double) {
        playbackPosition = seconds
        Task {
            try? await castCoordinator.seek(seconds: seconds)
        }
    }

    private func stopPlayback() {
        isPlaying = false
        selectedMediaName = nil
        Task {
            try? await castCoordinator.stop()
        }
    }
}
#endif
