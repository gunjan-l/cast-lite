#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct PaywallModal: View {
    @Binding public var isPresented: Bool
    public var subscriptionManager: SubscriptionManager
    public var onEntitlementUnlocked: () -> Void

    @State private var selectedSKU: SubscriptionSKU = .weekly
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    public init(
        isPresented: Binding<Bool>,
        subscriptionManager: SubscriptionManager,
        onEntitlementUnlocked: @escaping () -> Void = {}
    ) {
        self._isPresented = isPresented
        self.subscriptionManager = subscriptionManager
        self.onEntitlementUnlocked = onEntitlementUnlocked
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header badge
                    HStack {
                        Spacer()
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)

                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    VStack(spacing: 6) {
                        Text("Unlock Cast-Lite Pro")
                            .font(.title2.bold())
                        Text("Mirror screen with ultra-low latency & cast 4K media to any Smart TV or PC.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Feature highlights
                    VStack(alignment: .leading, spacing: 10) {
                        FeatureRow(icon: "bolt.fill", title: "Ultra Low-Latency Mirroring", subtitle: "MPEG-TS & MJPEG streaming engine")
                        FeatureRow(icon: "tv.fill", title: "Universal TV Support", subtitle: "Samsung, LG, Roku, Chromecast & DLNA")
                        FeatureRow(icon: "photo.fill", title: "Lossless 4K Media Casting", subtitle: "Direct streaming from Camera Roll & Web")
                        FeatureRow(icon: "nosign", title: "Zero Ads & Watermarks", subtitle: "Clean, professional presentation experience")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // SKU selection options
                    VStack(spacing: 12) {
                        ForEach(SubscriptionSKU.allCases, id: \.self) { sku in
                            Button(action: { selectedSKU = sku }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(sku.displayName)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            if sku == .weekly {
                                                Text("FREE TRIAL")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green)
                                                    .foregroundColor(.white)
                                                    .cornerRadius(4)
                                            } else if sku == .annual {
                                                Text("SAVE 84%")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue)
                                                    .foregroundColor(.white)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Text(sku.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Text(sku.priceDescription)
                                        .font(.subheadline.bold())
                                        .foregroundColor(selectedSKU == sku ? .blue : .primary)

                                    Image(systemName: selectedSKU == sku ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedSKU == sku ? .blue : .secondary)
                                }
                                .padding()
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedSKU == sku ? Color.blue : Color(.systemGray4), lineWidth: selectedSKU == sku ? 2 : 1)
                                    .background(selectedSKU == sku ? Color.blue.opacity(0.05) : Color(.systemBackground))
                                )
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Purchase CTA button
                    Button(action: executePurchase) {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(selectedSKU == .weekly ? "Start 3-Day Free Trial" : "Continue")
                                    .fontWeight(.bold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal)

                    // Restore & Legal disclosures
                    VStack(spacing: 8) {
                        Button(action: executeRestore) {
                            Text("Restore Purchases")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 16) {
                            Link("Terms of Service (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            Link("Privacy Policy", destination: URL(string: "https://castlite.app/privacy")!)
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func executePurchase() {
        isPurchasing = true
        Task {
            do {
                _ = try await subscriptionManager.mockPurchase(sku: selectedSKU)
                await MainActor.run {
                    self.isPurchasing = false
                    self.isPresented = false
                    self.onEntitlementUnlocked()
                }
            } catch {
                await MainActor.run {
                    self.isPurchasing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func executeRestore() {
        Task {
            _ = try? await subscriptionManager.mockRestore(entitlement: .active(sku: .annual, expiresDate: Date().addingTimeInterval(86400 * 365)))
            await MainActor.run {
                self.isPresented = false
                self.onEntitlementUnlocked()
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundColor(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
#endif
