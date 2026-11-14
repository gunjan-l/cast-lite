import Foundation
import CastCore

#if canImport(ReplayKit)
import ReplayKit
#if canImport(VideoToolbox)
import VideoToolbox
#endif

public class SampleHandler: RPBroadcastSampleHandler {

    // 50MB ReplayKit ceiling: strictly drop frames and terminate safely if memory climbs above 45MB
    private let maxMemoryLimitBytes: Int = 45 * 1024 * 1024
    private let ipcClient = IPCClient()
    private var isConnectedToMainApp: Bool = false
    private let ipcPort: UInt16 = 8999

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        Task {
            do {
                let connected = try await ipcClient.connect(port: ipcPort)
                self.isConnectedToMainApp = connected
            } catch {
                self.isConnectedToMainApp = false
            }
        }
    }

    public override func broadcastPaused() {
        // Paused state
    }

    public override func broadcastResumed() {
        // Resumed state
    }

    public override func broadcastFinished() {
        Task {
            await ipcClient.disconnect()
            self.isConnectedToMainApp = false
        }
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isConnectedToMainApp else { return }

        // Memory Guard: verify current process memory footprint
        if currentMemoryUsageBytes() > maxMemoryLimitBytes {
            // Drop frame to avoid extension crash
            return
        }

        switch sampleBufferType {
        case .video:
            // Extract PTS timestamp
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampMicros = UInt64(max(0, pts.seconds * 1_000_000))

            // In production, VTCompressionSession compresses CVPixelBuffer into H.264 NALUs.
            // Forward compressed frame packet over IPC
            let dummyNalu = Data([0x00, 0x00, 0x00, 0x01, 0x65]) // IDR slice marker
            let packet = IPCPacket(type: .video, isKeyframe: true, timestamp: timestampMicros, payload: dummyNalu)
            Task {
                try? await ipcClient.send(packet: packet)
            }

        case .audioApp, .audioMic:
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampMicros = UInt64(max(0, pts.seconds * 1_000_000))
            let packet = IPCPacket(type: .audio, isKeyframe: false, timestamp: timestampMicros, payload: Data())
            Task {
                try? await ipcClient.send(packet: packet)
            }

        @unknown default:
            break
        }
    }

    private func currentMemoryUsageBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
#else
public class SampleHandler {
    public let maxMemoryLimitBytes: Int = 45 * 1024 * 1024
    public private(set) var isConnected: Bool = false
    private let ipcClient = IPCClient()

    public init() {}

    public func start(port: UInt16 = 8999) async throws -> Bool {
        let connected = try await ipcClient.connect(port: port)
        isConnected = connected
        return connected
    }

    public func finish() async {
        await ipcClient.disconnect()
        isConnected = false
    }

    public func sendTestFrame(nalu: Data, timestamp: UInt64) async throws {
        guard isConnected else { return }
        let packet = IPCPacket(type: .video, isKeyframe: true, timestamp: timestamp, payload: nalu)
        try await ipcClient.send(packet: packet)
    }
}
#endif
