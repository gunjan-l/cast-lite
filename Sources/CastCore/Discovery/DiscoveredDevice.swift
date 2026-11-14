import Foundation

public enum DeviceType: Hashable, Sendable, Equatable {
    case chromecast
    case roku
    case dlna(brand: String)
    case web

    public var displayName: String {
        switch self {
        case .chromecast:
            return "Chromecast"
        case .roku:
            return "Roku"
        case .dlna(let brand):
            return "\(brand) (DLNA)"
        case .web:
            return "Web Browser"
        }
    }

    public var systemIcon: String {
        switch self {
        case .chromecast:
            return "tv"
        case .roku:
            return "play.tv"
        case .dlna:
            return "tv.fill"
        case .web:
            return "globe"
        }
    }
}

public struct DiscoveredDevice: Identifiable, Hashable, Sendable, Equatable {
    public let id: String
    public var name: String
    public let type: DeviceType
    public let ipAddress: String
    public let port: UInt16
    public let locationURL: URL?
    public var lastSeen: Date

    public init(
        id: String,
        name: String,
        type: DeviceType,
        ipAddress: String,
        port: UInt16,
        locationURL: URL? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.ipAddress = ipAddress
        self.port = port
        self.locationURL = locationURL
        self.lastSeen = lastSeen
    }

    public var controlURL: URL? {
        if let locationURL = locationURL {
            return locationURL
        }
        return URL(string: "http://\(ipAddress):\(port)/upnp/control/AVTransport1")
    }

    public func ecpURL(path: String) -> URL? {
        return URL(string: "http://\(ipAddress):\(port)/\(path)")
    }
}
