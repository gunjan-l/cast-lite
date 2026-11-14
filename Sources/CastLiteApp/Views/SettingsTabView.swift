#if canImport(SwiftUI)
import SwiftUI

public struct SettingsTabView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Subscription") {
                    HStack {
                        Text("Current Plan")
                        Spacer()
                        Text("Free Tier")
                            .foregroundColor(.secondary)
                    }

                    Button("Unlock Premium") {
                        // Triggers StoreKit 2 paywall modal
                    }
                    .foregroundColor(.blue)

                    Button("Restore Purchases") {
                        // Restores StoreKit 2 transactions
                    }
                }

                Section("Help & Information") {
                    NavigationLink("TV Setup & Connection Guide") {
                        Text("Ensure TV and iPhone are on the same Wi-Fi network.")
                            .padding()
                    }
                    Link("Terms of Service (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
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
