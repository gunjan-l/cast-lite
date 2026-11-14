#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct SettingsTabView: View {
    @State private var subscriptionManager = SubscriptionManager()
    @State private var entitlementStatus: EntitlementStatus = .inactive
    @State private var showPaywall = false
    @State private var restoreMessage: String?
    @State private var showRestoreAlert = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Subscription") {
                    HStack {
                        Text("Current Plan")
                        Spacer()
                        Text(entitlementStatus.description)
                            .foregroundColor(.secondary)
                    }

                    if !entitlementStatus.isEntitled {
                        Button("Unlock Premium (3-Day Free Trial)") {
                            showPaywall = true
                        }
                        .foregroundColor(.blue)
                        .fontWeight(.semibold)
                    }

                    Button("Restore Purchases") {
                        executeRestore()
                    }
                }

                Section("Help & Information") {
                    NavigationLink("TV Setup & Connection Guide") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Connecting your Smart TV")
                                .font(.title3.bold())
                            Text("1. Ensure your iPhone and Smart TV are connected to the same Wi-Fi network.")
                            Text("2. Open the Mirror tab and tap your TV name when it appears.")
                            Text("3. Tap 'Broadcast Screen' or 'Cast Video' to begin streaming.")
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
            .sheet(isPresented: $showPaywall) {
                PaywallModal(isPresented: $showPaywall, subscriptionManager: subscriptionManager) {
                    refreshStatus()
                }
            }
            .alert("Purchases Restored", isPresented: $showRestoreAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreMessage ?? "Your purchases have been successfully restored.")
            }
        }
        .onAppear {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        Task {
            let status = await subscriptionManager.status
            await MainActor.run {
                self.entitlementStatus = status
            }
        }
    }

    private func executeRestore() {
        Task {
            let restored = try? await subscriptionManager.mockRestore(entitlement: .active(sku: .annual, expiresDate: Date().addingTimeInterval(86400 * 365)))
            await MainActor.run {
                if let status = restored {
                    self.entitlementStatus = status
                    self.restoreMessage = "Successfully restored \(status.description)."
                } else {
                    self.restoreMessage = "No prior active subscriptions found."
                }
                self.showRestoreAlert = true
            }
        }
    }
}
#endif
