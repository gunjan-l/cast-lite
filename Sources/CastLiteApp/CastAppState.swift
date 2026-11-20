#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import Combine
import CastCore

@MainActor
public final class CastAppState: ObservableObject {
    public let coordinator: CastSessionCoordinator
    public let streamController: StreamController
    public let networkHelper: NetworkInterfaceHelper
    public let discoveryEngine: DiscoveryEngine
    public let subscriptionManager: SubscriptionManager

    @Published public var connectionState: CastConnectionState = .disconnected
    @Published public var selectedDevice: DiscoveredDevice? = nil
    @Published public var isStreaming: Bool = false
    @Published public var streamURL: String = ""
    @Published public var isPlaying: Bool = false
    @Published public var playbackPosition: Double = 0.0
    @Published public var currentVolume: Double = 80.0
    @Published public var errorMessage: String? = nil
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isScanning: Bool = false
    @Published public var isReconnecting: Bool = false

    public init(
        coordinator: CastSessionCoordinator = CastSessionCoordinator(),
        streamController: StreamController = StreamController(),
        networkHelper: NetworkInterfaceHelper = NetworkInterfaceHelper(),
        discoveryEngine: DiscoveryEngine = DiscoveryEngine(),
        subscriptionManager: SubscriptionManager = SubscriptionManager()
    ) {
        self.coordinator = coordinator
        self.streamController = streamController
        self.networkHelper = networkHelper
        self.discoveryEngine = discoveryEngine
        self.subscriptionManager = subscriptionManager

        setupStateObserver()
    }

    private func setupStateObserver() {
        Task {
            await coordinator.setOnConnectionStateChanged { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.connectionState = newState
                    self.isStreaming = (newState == .streaming)
                    if case .error(let msg) = newState {
                        self.errorMessage = msg
                    }
                    await self.syncCoordinatorProperties()
                }
            }
        }
    }

    public func syncCoordinatorProperties() async {
        let isPlay = await coordinator.isPlaying
        let pos = await coordinator.currentPositionSeconds
        let vol = await coordinator.currentVolume
        let dev = await coordinator.selectedDevice
        let err = await coordinator.errorMessage
        let isRecon = await coordinator.isReconnecting
        let mediaURL = await coordinator.currentMediaURL

        self.isPlaying = isPlay
        self.playbackPosition = pos
        self.currentVolume = vol * 100.0
        self.selectedDevice = dev
        self.errorMessage = err
        self.isReconnecting = isRecon
        if let mediaURL = mediaURL, !mediaURL.isEmpty {
            self.streamURL = mediaURL
        }
    }

    public func selectDevice(_ device: DiscoveredDevice?) {
        self.selectedDevice = device
        Task {
            await coordinator.selectDevice(device)
            if let dev = device {
                do {
                    try await coordinator.connect(to: dev)
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
            await syncCoordinatorProperties()
        }
    }

    public func connect(to device: DiscoveredDevice) {
        Task {
            do {
                try await coordinator.connect(to: device)
                await syncCoordinatorProperties()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func startScreenMirror() async throws -> String {
        let url = try await coordinator.startScreenMirror(
            streamController: streamController,
            networkHelper: networkHelper
        )
        self.isStreaming = true
        self.streamURL = url
        self.errorMessage = nil
        await syncCoordinatorProperties()
        return url
    }

    public func stopScreenMirror() async {
        try? await coordinator.stopScreenMirror(streamController: streamController)
        self.isStreaming = false
        self.streamURL = ""
        await syncCoordinatorProperties()
    }

    public func castMedia(name: String, url: String) async throws {
        guard let device = selectedDevice else {
            throw CastTransportError.notConnected
        }
        try await coordinator.castMedia(url: url, to: device, title: name)
        self.streamURL = url
        self.isPlaying = true
        await syncCoordinatorProperties()
    }

    public func play() {
        Task {
            try? await coordinator.play()
            self.isPlaying = true
        }
    }

    public func pause() {
        Task {
            try? await coordinator.pause()
            self.isPlaying = false
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(seconds: Double) {
        self.playbackPosition = seconds
        Task {
            try? await coordinator.seek(seconds: seconds)
        }
    }

    public func setVolume(sliderValue: Double) {
        self.currentVolume = sliderValue
        let normalized = max(0.0, min(1.0, sliderValue / 100.0))
        Task {
            try? await coordinator.setVolume(level: normalized)
        }
    }

    public func stopPlayback() {
        Task {
            if self.isStreaming {
                await self.streamController.stop()
            }
            try? await self.coordinator.stop()
            self.isPlaying = false
            self.streamURL = ""
            await self.syncCoordinatorProperties()
        }
    }

    public func startDiscovery() {
        Task {
            await discoveryEngine.setOnDevicesChanged { [weak self] devs in
                Task { @MainActor [weak self] in
                    self?.discoveredDevices = devs
                }
            }
            await discoveryEngine.startDiscovery()
            let devs = await discoveryEngine.devices
            self.discoveredDevices = devs
        }
    }

    public func refreshDevices() {
        self.isScanning = true
        Task {
            defer { self.isScanning = false }
            await discoveryEngine.setOnDevicesChanged { [weak self] devs in
                Task { @MainActor [weak self] in
                    self?.discoveredDevices = devs
                }
            }
            await discoveryEngine.restartDiscovery()
            await discoveryEngine.sendAllSSDPMSearches()
            let devs = await discoveryEngine.devices
            self.discoveredDevices = devs
        }
    }
}
#endif
