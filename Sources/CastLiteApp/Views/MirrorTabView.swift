#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct MirrorTabView: View {
    @ObservedObject public var appState: CastAppState
    @State private var showPermissionModal = false
    @State private var showPaywallModal = false
    @State private var hasGrantedLocalNetwork = false
    @State private var selectedQuality = 0 // 0: Ultra-Low Latency, 1: High Definition (1080p)

    public init(appState: CastAppState = CastAppState()) {
        self.appState = appState
    }

    public init(appState: CastAppState? = nil, networkHelper: NetworkInterfaceHelper = NetworkInterfaceHelper()) {
        if let state = appState {
            self.appState = state
        } else {
            self.appState = CastAppState(networkHelper: networkHelper)
        }
    }

    private var connectionStatusText: String {
        guard appState.selectedDevice != nil else {
            return "Tap to discover devices"
        }
        switch appState.connectionState {
        case .disconnected:
            return "Tap to discover devices"
        case .connecting:
            return "Connecting..."
        case .ready:
            return "Ready to Cast"
        case .streaming:
            return "Streaming Active"
        case .error(let message):
            return message
        }
    }

    private var connectionStatusDotColor: Color {
        guard appState.selectedDevice != nil else {
            return Color.gray
        }
        switch appState.connectionState {
        case .disconnected:
            return Color.gray
        case .connecting:
            return Color.orange
        case .ready:
            return Color.blue
        case .streaming:
            return Color.green
        case .error:
            return Color.red
        }
    }

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
                        Image(systemName: appState.selectedDevice?.type.systemIcon ?? "tv")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.selectedDevice?.name ?? "No TV Selected")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            Text(connectionStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(connectionStatusDotColor)
                            .frame(width: 8, height: 8)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .padding(.horizontal)

                // Error banner (e.g. "TV disconnected. Streaming stopped.")
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
                }

                // Mirror control card
                VStack(spacing: 14) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)

                    Text("Universal Screen Mirror")
                        .font(.title3.bold())

                    // Latency / Resolution mode picker
                    Picker("Streaming Mode", selection: $selectedQuality) {
                        Text("Low Latency (Gaming/Live)").tag(0)
                        Text("HD 1080p (Presentation)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if appState.isStreaming && !appState.streamURL.isEmpty {
                        VStack(spacing: 4) {
                            Text("Open on PC, Mac, or Smart TV Browser:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Text(appState.streamURL)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)
                                .padding(6)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }

                    Button(action: handleStartMirrorAction) {
                        HStack {
                            Image(systemName: appState.isStreaming ? "stop.fill" : "play.fill")
                            Text(appState.isStreaming ? "Stop Stream" : "Start Mirror")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(appState.isStreaming ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    // System Broadcast Picker button
                    HStack {
                        Text("iOS Screen Mirror:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        BroadcastPickerView(preferredExtension: "com.castlite.app.broadcast")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)

                // Device selector list
                DeviceSelectorView(
                    selectedDevice: Binding(
                        get: { appState.selectedDevice },
                        set: { newDev in
                            appState.selectDevice(newDev)
                        }
                    ),
                    devices: appState.discoveredDevices,
                    isScanning: appState.isScanning,
                    onRefresh: {
                        appState.refreshDevices()
                    }
                )
            }
            .navigationTitle("Cast-Lite")
            .sheet(isPresented: $showPermissionModal) {
                LocalNetworkPermissionModal(isPresented: $showPermissionModal) {
                    hasGrantedLocalNetwork = true
                    appState.refreshDevices()
                }
            }
            .sheet(isPresented: $showPaywallModal) {
                PaywallModal(isPresented: $showPaywallModal, subscriptionManager: appState.subscriptionManager) {
                    executeStartStreaming()
                }
            }
        }
        .onAppear {
            appState.startDiscovery()
        }
    }

    private func handleStartMirrorAction() {
        if appState.isStreaming {
            executeStopStreaming()
            return
        }

        Task {
            let entitled = await appState.subscriptionManager.isEntitled
            if entitled {
                executeStartStreaming()
            } else {
                await MainActor.run {
                    self.showPaywallModal = true
                }
            }
        }
    }

    private func executeStartStreaming() {
        Task {
            do {
                _ = try await appState.startScreenMirror()
            } catch {
                await MainActor.run {
                    appState.errorMessage = "Failed to start streaming: \(error.localizedDescription)"
                }
            }
        }
    }

    private func executeStopStreaming() {
        Task {
            await appState.stopScreenMirror()
        }
    }
}
#endif
