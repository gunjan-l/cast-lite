#if canImport(SwiftUI)
import SwiftUI
import CastCore

public struct DeviceSelectorView: View {
    @Binding public var selectedDevice: DiscoveredDevice?
    public var devices: [DiscoveredDevice]
    public var isScanning: Bool
    public var onRefresh: () -> Void

    public init(
        selectedDevice: Binding<DiscoveredDevice?>,
        devices: [DiscoveredDevice],
        isScanning: Bool = false,
        onRefresh: @escaping () -> Void = {}
    ) {
        self._selectedDevice = selectedDevice
        self.devices = devices
        self.isScanning = isScanning
        self.onRefresh = onRefresh
    }

    public var body: some View {
        List {
            Section(header: HStack {
                Text("Discovered Devices (\(devices.count))")
                Spacer()
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }) {
                if devices.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No devices found yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("Pull down or tap refresh to scan")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    ForEach(devices) { device in
                        Button(action: {
                            selectedDevice = device
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: device.type.systemIcon)
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(device.type.displayName) • \(device.ipAddress)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if selectedDevice?.id == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .refreshable {
            onRefresh()
        }
    }
}
#endif
