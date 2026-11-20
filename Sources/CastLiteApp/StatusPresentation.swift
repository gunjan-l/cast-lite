import Foundation
import CastCore

/// The app state that decides what the status area says. Plain values so the mapping stays pure.
struct StatusInput: Equatable {
    var connectionState: CastConnectionState
    var isScanning: Bool
    var isReconnecting: Bool
    var selectedDeviceName: String?
    var errorMessage: String?
    var localNetworkDeclined: Bool
}

/// What the user reads: one SF Symbol, a title, a subtitle, and optional error text.
struct StatusModel: Equatable {
    var symbol: String
    var title: String
    var subtitle: String
    var errorText: String?
}

enum StatusPresentation {
    static func status(for input: StatusInput) -> StatusModel {
        var model = base(for: input)
        // An error stays visible until app state clears it; the mapping never drops it.
        model.errorText = input.errorMessage ?? stateError(input.connectionState)
        return model
    }

    private static func stateError(_ state: CastConnectionState) -> String? {
        if case .error(let message) = state { return message }
        return nil
    }

    private static func base(for input: StatusInput) -> StatusModel {
        if input.localNetworkDeclined {
            return StatusModel(
                symbol: "wifi.exclamationmark",
                title: "Can't find TVs",
                subtitle: "Local Network access is off. Turn it on for Cast-Lite in Settings > Privacy & Security > Local Network."
            )
        }

        guard let tv = input.selectedDeviceName else {
            if input.isScanning {
                return StatusModel(
                    symbol: "magnifyingglass",
                    title: "Looking for TVs",
                    subtitle: "Make sure your TV is on and on the same Wi-Fi."
                )
            }
            return StatusModel(
                symbol: "tv",
                title: "Choose a TV",
                subtitle: "Pick a TV to mirror your screen to."
            )
        }

        if input.isReconnecting {
            return StatusModel(
                symbol: "arrow.triangle.2.circlepath",
                title: "Reconnecting",
                subtitle: "Lost contact with \(tv). Trying to get back."
            )
        }

        switch input.connectionState {
        case .disconnected:
            return StatusModel(symbol: "tv", title: "Not connected", subtitle: "\(tv) is selected. Start broadcasting to mirror.")
        case .connecting:
            return StatusModel(symbol: "antenna.radiowaves.left.and.right", title: "Connecting", subtitle: "Reaching \(tv).")
        case .ready:
            return StatusModel(symbol: "checkmark.circle", title: "Ready", subtitle: "Connected to \(tv). Start broadcasting to mirror.")
        case .streaming:
            return StatusModel(symbol: "tv.badge.wifi", title: "Mirroring", subtitle: "Your screen is on \(tv).")
        case .error:
            return StatusModel(symbol: "exclamationmark.triangle", title: "Connection problem", subtitle: "Couldn't mirror to \(tv).")
        }
    }
}

/// Spoken text for status transitions. Only started, failed and recovered speak;
/// everything else is visible but silent so VoiceOver isn't chatty.
enum StatusAnnouncement {
    static func text(from oldInput: StatusInput?, to newInput: StatusInput) -> String? {
        guard let oldInput, oldInput != newInput else { return nil }
        let old = StatusPresentation.status(for: oldInput)
        let new = StatusPresentation.status(for: newInput)
        guard old != new else { return nil }

        if let error = new.errorText {
            return old.errorText == error ? nil : "\(new.title). \(error)"
        }

        let recovering = old.errorText != nil || oldInput.isReconnecting
        let wasStreaming = oldInput.connectionState == .streaming
        switch newInput.connectionState {
        case .streaming where !wasStreaming:
            if recovering { return "Mirroring resumed." }
            return "Mirroring started on \(newInput.selectedDeviceName ?? "your TV")."
        case .ready where recovering:
            return "Connection recovered."
        default:
            return nil
        }
    }
}

/// Light haptic on Start and on a user Stop only; a stream that ended with an
/// error message (disconnect, failure) stays silent.
enum MirrorHaptic {
    static func shouldFire(wasStreaming: Bool, isStreaming: Bool, errorMessage: String?) -> Bool {
        guard wasStreaming != isStreaming else { return false }
        return isStreaming || errorMessage == nil
    }
}
