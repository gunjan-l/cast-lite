#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct MirrorTabView: View {
    @State private var isStreaming = false
    @State private var streamURL = ""
    @State private var streamController = StreamController()
    @State private var discoveryEngine = DiscoveryEngine()
    @State private var discoveredDevices: [DiscoveredDevice] = []
    @State private var selectedDevice: DiscoveredDevice?
    @State private var showPermissionModal = false
    @State private var hasGrantedLocalNetwork = false
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Connection bar with selected device
                Button(action: {
                    if !hasGrantedLocalNetwork {
                        showPermissionModal = true
                    }
                }) {
                    HStack {
                        Image(systemName: selectedDevice?.type.systemIcon ?? "tv")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDevice?.name ?? "No TV Selected")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            Text(isStreaming ? "Streaming Active" : (selectedDevice == nil ? "Tap to discover devices" : "Connected"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(isStreaming ? Color.green : (selectedDevice == nil ? Color.gray : Color.blue))
                            .frame(width: 8, height: 8)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .padding(.horizontal)

                // Mirror control card
                VStack(spacing: 16) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("Universal Screen Mirror")
                        .font(.title3.bold())

                    if isStreaming && !streamURL.isEmpty {
                        VStack(spacing: 4) {
                            Text("Live Web Stream:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Text(streamURL)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)
                        }
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

                    // System Broadcast Picker button
                    HStack {
                        Text("iOS Screen Mirror:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        BroadcastPickerView(preferredExtension: "com.castlite.broadcast")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)

                // Device selector list
                DeviceSelectorView(
                    selectedDevice: $selectedDevice,
                    devices: discoveredDevices,
                    isScanning: false,
                    onRefresh: {
                        refreshDevices()
                    }
                )

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Cast-Lite")
            .sheet(isPresented: $showPermissionModal) {
                LocalNetworkPermissionModal(isPresented: $showPermissionModal) {
                    hasGrantedLocalNetwork = true
                    refreshDevices()
                }
            }
        }
        .onAppear {
            loadInitialDevices()
        }
    }

    private func loadInitialDevices() {
        Task {
            let devs = await discoveryEngine.devices
            await MainActor.run {
                self.discoveredDevices = devs
            }
        }
    }

    private func refreshDevices() {
        Task {
            await discoveryEngine.sendSSDPMSearch()
            let devs = await discoveryEngine.devices
            await MainActor.run {
                self.discoveredDevices = devs
            }
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
