import Foundation
import CastCore

print("""
======================================================
  Cast-Lite Screencast & Streaming Server
======================================================
Starting embedded streaming engine in Podman...
""")

let streamController = StreamController(port: 8080)
let discoveryEngine = DiscoveryEngine()

Task {
    do {
        let port = try await streamController.start()
        print("\nStreaming server active on port \(port)!")
        print("  - Web Stream Viewer:   http://localhost:\(port)/view")
        print("  - Live HLS Playlist:   http://localhost:\(port)/stream.m3u8")
        print("  - Live MJPEG Stream:   http://localhost:\(port)/stream")
        print("  - Server Status API:   http://localhost:\(port)/status\n")

        print("Scanning local network for Smart TVs (SSDP/mDNS)...")
        await discoveryEngine.startDiscovery()
        await discoveryEngine.sendSSDPMSearch()

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let found = await discoveryEngine.devices
        if found.isEmpty {
            print("No TVs discovered on this subnet yet. Ready for browser connections.")
        } else {
            print("Discovered Smart TVs on local network:")
            for dev in found {
                print("  - [\(dev.type.displayName)] \(dev.name) at \(dev.ipAddress):\(dev.port)")
            }
        }
        print("\nServer running. Open http://localhost:\(port)/view in browser. Press Ctrl+C to stop.\n")
    } catch {
        print("Failed to start streaming server: \(error)")
    }
}

RunLoop.main.run()
