import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor CastSessionCoordinator {
    public private(set) var activeDevice: DiscoveredDevice?
    public private(set) var currentMediaURL: String?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentPositionSeconds: Double = 0

    public init() {}

    public func castMedia(url: String, to device: DiscoveredDevice) async throws {
        self.activeDevice = device
        self.currentMediaURL = url
        self.isPlaying = true
        self.currentPositionSeconds = 0

        switch device.type {
        case .roku:
            let launchURL = RokuECPClient.buildLaunchURL(deviceIP: device.ipAddress, mediaURL: url)
            await sendHTTPPost(url: launchURL)

        case .dlna:
            let soap = UPnPClient.generateSetAVTransportURIPayload(mediaURL: url)
            await sendSOAP(action: "SetAVTransportURI", payload: soap, on: device)
            try? await play()

        case .chromecast:
            if let dialURL = URL(string: "http://\(device.ipAddress):8008/apps/CC1AD845") {
                await sendHTTPPost(url: dialURL)
            }

        case .web:
            break
        }
    }

    public func play() async throws {
        guard let device = activeDevice else { return }
        self.isPlaying = true

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play")
            await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generatePlayPayload()
            await sendSOAP(action: "Play", payload: soap, on: device)

        case .chromecast, .web:
            break
        }
    }

    public func pause() async throws {
        guard let device = activeDevice else { return }
        self.isPlaying = false

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play")
            await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generatePausePayload()
            await sendSOAP(action: "Pause", payload: soap, on: device)

        case .chromecast, .web:
            break
        }
    }

    public func stop() async throws {
        guard let device = activeDevice else { return }
        self.isPlaying = false
        self.currentMediaURL = nil

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Back")
            await sendHTTPPost(url: url)

        case .dlna:
            let soap = UPnPClient.generateStopPayload()
            await sendSOAP(action: "Stop", payload: soap, on: device)

        case .chromecast, .web:
            break
        }
    }

    public func seek(seconds: Double) async throws {
        guard let device = activeDevice else { return }
        self.currentPositionSeconds = seconds

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let timeString = String(format: "%02d:%02d:%02d", hours, minutes, secs)

        if case .dlna = device.type {
            let soap = UPnPClient.generateSeekPayload(targetTime: timeString)
            await sendSOAP(action: "Seek", payload: soap, on: device)
        }
    }

    private func sendSOAP(action: String, payload: String, on device: DiscoveredDevice) async {
        guard let controlURL = device.controlURL else { return }
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(payload.utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendHTTPPost(url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }
}
