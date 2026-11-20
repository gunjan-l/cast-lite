#if canImport(SwiftUI)
import SwiftUI
import CastCore

/// Content of the TV picker sheet. The presenting view owns dismissal: it
/// closes the sheet when `selectedDevice` is set to a non-nil value.
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
            if devices.isEmpty && !isScanning {
                VStack(spacing: 8) {
                    Image(systemName: "tv.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No TVs found")
                        .font(.headline)
                    Text("Check that your iPhone and TV are on the same Wi-Fi network, then refresh.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Refresh", action: onRefresh)
                        .frame(minHeight: 44)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(devices) { device in
                        deviceRow(device)
                    }
                } header: {
                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching for TVs…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { onRefresh() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Refresh")
                .disabled(isScanning)
            }
        }
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        let isSelected = selectedDevice?.id == device.id
        return Button {
            selectedDevice = device
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.type.systemIcon)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .foregroundStyle(.primary)
                    Text("\(device.type.displayName) • \(device.ipAddress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG && canImport(Combine)
private struct DevicePickerPreview: View {
    @StateObject var state: CastAppState
    var body: some View {
        NavigationStack {
            DeviceSelectorView(
                selectedDevice: Binding(
                    get: { state.selectedDevice },
                    set: { state.selectedDevice = $0 }
                ),
                devices: state.discoveredDevices,
                isScanning: state.isScanning,
                onRefresh: {}
            )
            .navigationTitle("Choose a TV")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Picker - scanning") {
    DevicePickerPreview(state: .preview(.scanning))
}
#Preview("Picker - populated") {
    DevicePickerPreview(state: .preview(.streaming))
}
#Preview("Picker - empty") {
    DevicePickerPreview(state: .preview(.noDevices))
}
#endif
#endif
