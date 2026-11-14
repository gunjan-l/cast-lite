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
            var request = URLRequest(url: launchURL)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)

        case .dlna:
            guard let locationURL = device.locationURL ?? URL(string: "http://\(device.ipAddress):\(device.port)/upnp/control/AVTransport1") else {
                return
            }
            let soap = UPnPClient.generateSetAVTransportURIPayload(mediaURL: url)
            var request = URLRequest(url: locationURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"", forHTTPHeaderField: "SOAPACTION")
            request.httpBody = Data(soap.utf8)
            _ = try? await URLSession.shared.data(for: request)

            // Issue play command
            try? await play()

        case .chromecast, .web:
            // Handled via Cast V2 / HTML5 viewer
            break
        }
    }

    public func play() async throws {
        guard let device = activeDevice else { return }
        self.isPlaying = true

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)

        case .dlna:
            guard let locationURL = device.locationURL ?? URL(string: "http://\(device.ipAddress):\(device.port)/upnp/control/AVTransport1") else { return }
            let soap = UPnPClient.generatePlayPayload()
            var request = URLRequest(url: locationURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#Play\"", forHTTPHeaderField: "SOAPACTION")
            request.httpBody = Data(soap.utf8)
            _ = try? await URLSession.shared.data(for: request)

        case .chromecast, .web:
            break
        }
    }

    public func pause() async throws {
        guard let device = activeDevice else { return }
        self.isPlaying = false

        switch device.type {
        case .roku:
            let url = RokuECPClient.buildKeypressURL(deviceIP: device.ipAddress, key: "Play") // Play/Pause toggle
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)

        case .dlna:
            guard let locationURL = device.locationURL ?? URL(string: "http://\(device.ipAddress):\(device.port)/upnp/control/AVTransport1") else { return }
            let soap = UPnPClient.generatePausePayload()
            var request = URLRequest(url: locationURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#Pause\"", forHTTPHeaderField: "SOAPACTION")
            request.httpBody = Data(soap.utf8)
            _ = try? await URLSession.shared.data(for: request)

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
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)

        case .dlna:
            guard let locationURL = device.locationURL ?? URL(string: "http://\(device.ipAddress):\(device.port)/upnp/control/AVTransport1") else { return }
            let soap = UPnPClient.generateStopPayload()
            var request = URLRequest(url: locationURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#Stop\"", forHTTPHeaderField: "SOAPACTION")
            request.httpBody = Data(soap.utf8)
            _ = try? await URLSession.shared.data(for: request)

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
            guard let locationURL = device.locationURL ?? URL(string: "http://\(device.ipAddress):\(device.port)/upnp/control/AVTransport1") else { return }
            let soap = UPnPClient.generateSeekPayload(targetTime: timeString)
            var request = URLRequest(url: locationURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#Seek\"", forHTTPHeaderField: "SOAPACTION")
            request.httpBody = Data(soap.utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
