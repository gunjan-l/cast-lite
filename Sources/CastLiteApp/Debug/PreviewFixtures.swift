#if DEBUG && canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import CastCore

/// Debug-only fake app state for SwiftUI previews. Compiled out of release builds.
/// Extend `Scenario` to add a state; every preview that needs one calls `CastAppState.preview(_:)`.
@MainActor
enum PreviewFixtures {
    enum Scenario {
        case idle
        case scanning
        case streaming
        case error
        case noDevices
    }

    static let livingRoomTV = DiscoveredDevice(
        id: "preview-living-room", name: "Living Room TV", type: .chromecast,
        ipAddress: "192.168.1.20", port: 8009
    )
    static let bedroomRoku = DiscoveredDevice(
        id: "preview-bedroom", name: "Bedroom Roku", type: .roku,
        ipAddress: "192.168.1.21", port: 8060
    )

    static func appState(_ scenario: Scenario) -> CastAppState {
        let state = CastAppState()
        switch scenario {
        case .idle:
            state.discoveredDevices = [livingRoomTV, bedroomRoku]
        case .noDevices:
            break
        case .scanning:
            state.isScanning = true
        case .streaming:
            state.discoveredDevices = [livingRoomTV, bedroomRoku]
            state.selectedDevice = livingRoomTV
            state.connectionState = .streaming
            state.isStreaming = true
            state.streamURL = "http://192.168.1.10:8080/mirror"
        case .error:
            state.discoveredDevices = [livingRoomTV, bedroomRoku]
            state.selectedDevice = livingRoomTV
            state.connectionState = .error("TV disconnected. Streaming stopped.")
            state.errorMessage = "TV disconnected. Streaming stopped."
        }
        return state
    }
}

extension CastAppState {
    static func preview(_ scenario: PreviewFixtures.Scenario) -> CastAppState {
        PreviewFixtures.appState(scenario)
    }
}
#endif
