#if canImport(SwiftUI)
import SwiftUI
import CastCore

@MainActor
public struct RootView: View {
    @StateObject private var appState: CastAppState

    public init(appState: CastAppState? = nil) {
        if let state = appState {
            _appState = StateObject(wrappedValue: state)
        } else {
            _appState = StateObject(wrappedValue: CastAppState())
        }
    }

    public var body: some View {
        MirrorView(appState: appState)
            .environmentObject(appState)
    }
}
#endif
