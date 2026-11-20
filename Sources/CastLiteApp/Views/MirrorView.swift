#if canImport(SwiftUI)
import SwiftUI
import CastCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct MirrorView: View {
    @ObservedObject public var appState: CastAppState
    @State private var showSettings = false
    @State private var showPermissionModal = false
    @State private var showDevicePicker = false
    @State private var hasGrantedLocalNetwork = false
    @State private var localNetworkDeclined: Bool
    @State private var lastAnnouncedInput: StatusInput?

    public init(
        appState: CastAppState? = nil,
        networkHelper: NetworkInterfaceHelper = NetworkInterfaceHelper(),
        localNetworkDeclined: Bool = false
    ) {
        self._localNetworkDeclined = State(initialValue: localNetworkDeclined)
        if let state = appState {
            self.appState = state
        } else {
            self.appState = CastAppState(networkHelper: networkHelper)
        }
    }

    private var statusInput: StatusInput {
        StatusInput(
            connectionState: appState.connectionState,
            isScanning: appState.isScanning,
            isReconnecting: appState.isReconnecting,
            selectedDeviceName: appState.selectedDevice?.name,
            errorMessage: appState.errorMessage,
            localNetworkDeclined: localNetworkDeclined
        )
    }

    private var status: StatusModel { StatusPresentation.status(for: statusInput) }

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
                            set: { pickedDevice in
                                appState.selectDevice(pickedDevice)
                                if pickedDevice != nil { showDevicePicker = false }
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
            .sheet(isPresented: $showPermissionModal, onDismiss: {
                // Closing the sheet without the button is a decline.
                localNetworkDeclined = !hasGrantedLocalNetwork
            }) {
                LocalNetworkPermissionModal(isPresented: $showPermissionModal) {
                    hasGrantedLocalNetwork = true
                    localNetworkDeclined = false
                    appState.refreshDevices()
                }
            }
        }
        .onAppear {
            appState.startDiscovery()
            lastAnnouncedInput = statusInput
        }
        // Start is the system broadcast picker, which gives no callback. The
        // streaming flag flipping is the observable moment mirroring starts or
        // stops; MirrorHaptic keeps error-driven stops silent.
        .onChange(of: appState.isStreaming) { isStreaming in
            if MirrorHaptic.shouldFire(
                wasStreaming: !isStreaming,
                isStreaming: isStreaming,
                errorMessage: appState.errorMessage
            ) {
                Self.lightHaptic()
            }
        }
        .onChange(of: statusInput) { new in
            if let text = StatusAnnouncement.text(from: lastAnnouncedInput, to: new) {
                Self.announce(text)
            }
            lastAnnouncedInput = new
        }
    }

    private static func lightHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // UIAccessibility.post is iOS 16-safe; AccessibilityNotification is iOS 17.
    private static func announce(_ text: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
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
                    .accessibilityAddTraits(.isHeader)
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
                    .accessibilityHidden(true)
                Text(appState.selectedDevice?.name ?? "Choose a TV")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(appState.selectedDevice.map { "TV, \($0.name)" } ?? "Choose a TV")
        .accessibilityHint("Opens the list of TVs")
    }

    private var broadcastBar: some View {
        HStack {
            Text("Start Mirroring")
                .font(.headline)
                .accessibilityHidden(true)
            Spacer()
            BroadcastPickerView(preferredExtension: "com.castlite.app.broadcast")
                .frame(width: 44, height: 44)
                .accessibilityLabel("Start or stop mirroring")
                .accessibilityHint(appState.selectedDevice == nil
                    ? "Choose a TV first"
                    : "Opens the system screen broadcast sheet")
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
#Preview("Local Network declined") {
    MirrorView(appState: .preview(.noDevices), localNetworkDeclined: true)
}
#endif
#endif
