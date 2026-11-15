#if canImport(SwiftUI)
import SwiftUI
import CastCore

@MainActor
public struct MainTabView: View {
    @StateObject private var appState: CastAppState
    @State private var selectedTab: Int = 0

    public init(appState: CastAppState? = nil) {
        if let state = appState {
            _appState = StateObject(wrappedValue: state)
        } else {
            _appState = StateObject(wrappedValue: CastAppState())
        }
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            MirrorTabView(appState: appState)
                .tabItem {
                    Label("Mirror", systemImage: "tv.and.mediabox")
                }
                .tag(0)

            CastTabView(appState: appState)
                .tabItem {
                    Label("Cast", systemImage: "photo.on.rectangle.angled")
                }
                .tag(1)

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .environmentObject(appState)
        .accentColor(.blue)
    }
}
#endif
