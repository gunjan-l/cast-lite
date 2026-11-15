#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct MirrorTabView: View {
    @State private var isStreaming = false
    @State private var streamURL = ""
    @State private var streamController = StreamController()
    @State private var discoveryEngine = DiscoveryEngine()
    @State private var subscriptionManager = SubscriptionManager()
    @State private var discoveredDevices: [DiscoveredDevice] = []
    @State private var selectedDevice: DiscoveredDevice?
    @State private var showPermissionModal = false
    @State private var showPaywallModal = false
    @State private var hasGrantedLocalNetwork = false
    @State private var selectedQuality = 0 // 0: Ultra-Low Latency, 1: High Definition (1080p)
    @State private var errorMessage: String?
    private let networkHelper: NetworkInterfaceHelper

    public init(networkHelper: NetworkInterfaceHelper = NetworkInterfaceHelper()) {
        self.networkHelper = networkHelper
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

                    if isStreaming && !streamURL.isEmpty {
                        VStack(spacing: 4) {
                            Text("Open on PC, Mac, or Smart TV Browser:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Text(streamURL)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)
                                .padding(6)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }

                    Button(action: handleStartMirrorAction) {
                        HStack {
                            Image(systemName: isStreaming ? "stop.fill" : "play.fill")
                            Text(isStreaming ? "Stop Stream" : "Start Mirror")
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
                        BroadcastPickerView(preferredExtension: "com.castlite.app.broadcast")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)

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
            .sheet(isPresented: $showPaywallModal) {
                PaywallModal(isPresented: $showPaywallModal, subscriptionManager: subscriptionManager) {
                    executeStartStreaming()
                }
            }
        }
        .onAppear {
            loadInitialDevices()
        }
    }

    private func handleStartMirrorAction() {
        if isStreaming {
            executeStopStreaming()
            return
        }

        Task {
            let entitled = await subscriptionManager.isEntitled
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
                let port = try await streamController.start()
                let (url, resolution) = networkHelper.resolveStreamURL(port: port)
                await MainActor.run {
                    self.isStreaming = true
                    self.streamURL = url
                    if resolution.isFallback {
                        self.errorMessage = resolution.warningMessage
                    } else {
                        self.errorMessage = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to start server: \(error.localizedDescription)"
                }
            }
        }
    }

    private func executeStopStreaming() {
        Task {
            await streamController.stop()
            await MainActor.run {
                self.isStreaming = false
                self.streamURL = ""
                self.errorMessage = nil
            }
        }
    }

    private func loadInitialDevices() {
        Task {
            await discoveryEngine.setOnDevicesChanged { devs in
                Task { @MainActor in
                    self.discoveredDevices = devs
                }
            }
            await discoveryEngine.startDiscovery()
            await discoveryEngine.sendSSDPMSearch()
            let devs = await discoveryEngine.devices
            await MainActor.run {
                self.discoveredDevices = devs
            }
        }
    }

    private func refreshDevices() {
        Task {
            await discoveryEngine.setOnDevicesChanged { devs in
                Task { @MainActor in
                    self.discoveredDevices = devs
                }
            }
            await discoveryEngine.startDiscovery()
            await discoveryEngine.sendSSDPMSearch()
            let devs = await discoveryEngine.devices
            await MainActor.run {
                self.discoveredDevices = devs
            }
        }
    }
}
#endif
