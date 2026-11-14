#if canImport(SwiftUI)
import SwiftUI

public struct MainTabView: View {
    @State private var selectedTab: Int = 0

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            MirrorTabView()
                .tabItem {
                    Label("Mirror", systemImage: "tv.and.mediabox")
                }
                .tag(0)

            CastTabView()
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
        .accentColor(.blue)
    }
}
#endif
