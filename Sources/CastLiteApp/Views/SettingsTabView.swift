#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct SettingsTabView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Help & Information") {
                    NavigationLink("TV Setup & Connection Guide") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Connecting your Smart TV")
                                .font(.title3.bold())
                            Text("1. Ensure your iPhone and Smart TV are connected to the same Wi-Fi network.")
                            Text("2. Open the Mirror tab and tap your TV name when it appears.")
                            Text("3. Tap the broadcast button and start the broadcast to begin mirroring.")
                            Spacer()
                        }
                        .padding()
                    }
                    Link("Terms of Service (Apple Standard EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Link("Privacy Policy", destination: URL(string: "https://castlite.app/privacy")!)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (Build 1)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
