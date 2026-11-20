#if canImport(SwiftUI)
import SwiftUI

#if canImport(ReplayKit) && canImport(UIKit)
import UIKit
import ReplayKit

public struct BroadcastPickerView: UIViewRepresentable {
    public let preferredExtension: String?

    public init(preferredExtension: String? = nil) {
        self.preferredExtension = preferredExtension
    }

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = false

        // Customise tint if needed
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.tintColor = .systemBlue
            }
        }

        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // Mirror SwiftUI's .disabled onto the system picker's inner button.
        for case let button as UIButton in uiView.subviews {
            button.isEnabled = context.environment.isEnabled
            button.accessibilityLabel = "Start or stop mirroring"
        }
    }
}
#else
public struct BroadcastPickerView: View {
    public let preferredExtension: String?

    public init(preferredExtension: String? = nil) {
        self.preferredExtension = preferredExtension
    }

    public var body: some View {
        Button(action: {}) {
            HStack {
                Image(systemName: "record.circle")
                Text("Broadcast Screen")
            }
            .padding(10)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
    }
}
#endif
#endif
