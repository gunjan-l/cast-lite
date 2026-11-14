#if canImport(SwiftUI)
import SwiftUI

public struct CastTabView: View {
    @State private var selectedSegment = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack {
                Picker("Media Source", selection: $selectedSegment) {
                    Text("Camera Roll").tag(0)
                    Text("Web Browser").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                Spacer()

                if selectedSegment == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Photos & Videos")
                            .font(.headline)
                        Text("Select personal media to cast in full resolution directly to smart TV.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Web Video Caster")
                            .font(.headline)
                        Text("Browse video websites and cast HTML5 videos directly with one tap.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .navigationTitle("Cast Media")
        }
    }
}
#endif
