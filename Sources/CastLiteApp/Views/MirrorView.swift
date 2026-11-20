#if canImport(SwiftUI)
import SwiftUI
import CastCore

@MainActor
public struct MirrorView: View {
    @ObservedObject public var appState: CastAppState
    @State private var showSettings = false
    @State private var showPermissionModal = false
    @State private var showDevicePicker = false
    @State private var hasGrantedLocalNetwork = false

    public init(appState: CastAppState? = nil, networkHelper: NetworkInterfaceHelper = NetworkInterfaceHelper()) {
        if let state = appState {
            self.appState = state
        } else {
            self.appState = CastAppState(networkHelper: networkHelper)
        }
    }

    private var status: StatusModel {
        StatusPresentation.status(for: StatusInput(
            connectionState: appState.connectionState,
            isScanning: appState.isScanning,
            isReconnecting: appState.isReconnecting,
            selectedDeviceName: appState.selectedDevice?.name,
            errorMessage: appState.errorMessage,
            localNetworkDeclined: false
        ))
    }

    public var body: some View {
        NavigationStack {
            List {
                statusSection
                Section {
                    tvRow
                    if appState.isStreaming && !appState.streamURL.isEmpty {
                        LabeledContent("Open in a browser", value: appState.streamURL)
                            .textSelection(.disabled)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { broadcastBar }
            .navigationTitle("Cast-Lite")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showDevicePicker) {
                NavigationStack {
                    DeviceSelectorView(
                        selectedDevice: Binding(
                            get: { appState.selectedDevice },
                            set: { newDev in
                                appState.selectDevice(newDev)
                                if newDev != nil { showDevicePicker = false }
                            }
                        ),
                        devices: appState.discoveredDevices,
                        isScanning: appState.isScanning,
                        onRefresh: { appState.refreshDevices() }
                    )
                    .navigationTitle("Choose a TV")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDevicePicker = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showPermissionModal) {
                LocalNetworkPermissionModal(isPresented: $showPermissionModal) {
                    hasGrantedLocalNetwork = true
                    appState.refreshDevices()
                }
            }
        }
        .onAppear {
            appState.startDiscovery()
        }
    }

    private var statusSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: status.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(status.title)
                    .font(.title2.bold())
                Text(status.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let errorText = status.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var tvRow: some View {
        Button {
            if hasGrantedLocalNetwork {
                showDevicePicker = true
            } else {
                showPermissionModal = true
            }
        } label: {
            HStack {
                Image(systemName: appState.selectedDevice?.type.systemIcon ?? "tv")
                    .foregroundStyle(.tint)
                Text(appState.selectedDevice?.name ?? "Choose a TV")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var broadcastBar: some View {
        HStack {
            Text("Start Mirroring")
                .font(.headline)
            Spacer()
            BroadcastPickerView(preferredExtension: "com.castlite.app.broadcast")
                .frame(width: 44, height: 44)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(appState.selectedDevice == nil)
    }
}

#if DEBUG
#Preview("Idle") { MirrorView(appState: .preview(.idle)) }
#Preview("Scanning") { MirrorView(appState: .preview(.scanning)) }
#Preview("Streaming") { MirrorView(appState: .preview(.streaming)) }
#Preview("Error") { MirrorView(appState: .preview(.error)) }
#endif
#endif
