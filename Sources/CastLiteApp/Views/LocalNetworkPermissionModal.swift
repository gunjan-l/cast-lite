#if canImport(SwiftUI)
import SwiftUI

public struct LocalNetworkPermissionModal: View {
    @Binding public var isPresented: Bool
    public var onAllow: () -> Void

    public init(isPresented: Binding<Bool>, onAllow: @escaping () -> Void) {
        self._isPresented = isPresented
        self.onAllow = onAllow
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 56))
                .foregroundColor(.blue)
                .padding(.top, 24)

            Text("Local Network Access")
                .font(.title2.bold())

            Text("Cast-Lite needs permission to discover Smart TVs, streaming devices, and computers on your Wi-Fi network.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                Label("Discover Samsung, LG, Roku & Chromecast TVs", systemImage: "tv")
                Label("Stream live video without internet upload", systemImage: "bolt.fill")
                Label("Your media stays 100% private on your home network", systemImage: "lock.shield.fill")
            }
            .font(.subheadline)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()

            Button(action: {
                isPresented = false
                onAllow()
            }) {
                Text("Continue & Allow Access")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)

            Button(action: {
                isPresented = false
            }) {
                Text("Not Now")
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 16)
        }
        .padding()
    }
}
#endif
