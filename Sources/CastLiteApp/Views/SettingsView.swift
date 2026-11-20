#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (Build \(build))"
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Help & Information") {
                    NavigationLink("TV Setup & Connection Guide") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Connecting your Smart TV")
                                .font(.title3.bold())
                            Text("1. Ensure your iPhone and Smart TV are connected to the same Wi-Fi network.")
                            Text("2. On the main screen, tap the TV row and choose your TV from the list.")
                            Text("3. Tap Start to begin mirroring your screen to the TV.")
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
                        Text(Self.versionString)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
#endif
