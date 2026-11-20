#if canImport(SwiftUI)
import SwiftUI

/// Explains why Cast-Lite needs Local Network access before the system asks.
/// One symbol, one headline, two short lines, one primary button.
/// Dismissing the sheet without tapping the button counts as declining; the presenter decides what that means.
public struct LocalNetworkPermissionModal: View {
    @Binding public var isPresented: Bool
    public var onAllow: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 48

    public init(isPresented: Binding<Bool>, onAllow: @escaping () -> Void) {
        self._isPresented = isPresented
        self.onAllow = onAllow
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi")
                .font(.system(size: symbolSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Find TVs on your Wi-Fi")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                Text("Cast-Lite needs Local Network access to see TVs near you.")
                Text("Your screen stays on your home network.")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            Button {
                isPresented = false
                onAllow()
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium, .large]) // .large so the largest text sizes don't clip
    }
}

#if DEBUG
#Preview("Permission sheet") {
    LocalNetworkPermissionModal(isPresented: .constant(true), onAllow: {})
}
#endif
#endif
