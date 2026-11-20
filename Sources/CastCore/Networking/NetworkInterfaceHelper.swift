import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct NetworkInterface: Equatable, Sendable {
    public let name: String
    public let address: String
    public let isIPv4: Bool
    public let isUp: Bool
    public let isLoopback: Bool

    public init(
        name: String,
        address: String,
        isIPv4: Bool = true,
        isUp: Bool = true,
        isLoopback: Bool = false
    ) {
        self.name = name
        self.address = address
        self.isIPv4 = isIPv4
        self.isUp = isUp
        self.isLoopback = isLoopback
    }
}

public protocol NetworkInterfaceProvider: Sendable {
    func getInterfaces() -> [NetworkInterface]
}

public struct MockNetworkInterfaceProvider: NetworkInterfaceProvider {
    public var interfaces: [NetworkInterface]

    public init(interfaces: [NetworkInterface] = []) {
        self.interfaces = interfaces
    }

    public func getInterfaces() -> [NetworkInterface] {
        return interfaces
    }
}

public struct SystemNetworkInterfaceProvider: NetworkInterfaceProvider {
    public init() {}

    public func getInterfaces() -> [NetworkInterface] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        var results: [NetworkInterface] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }

            guard let namePtr = ptr.pointee.ifa_name else { continue }
            let name = String(cString: namePtr)

            guard let addrPtr = ptr.pointee.ifa_addr else { continue }
            let family = Int32(addrPtr.pointee.sa_family)

            let flags = UInt32(ptr.pointee.ifa_flags)
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0

            if family == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = UnsafeRawPointer(addrPtr).load(as: sockaddr_in.self)
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let address = String(cString: buffer)
                    if !address.isEmpty {
                        results.append(NetworkInterface(
                            name: name,
                            address: address,
                            isIPv4: true,
                            isUp: isUp,
                            isLoopback: isLoopback
                        ))
                    }
                }
            } else if family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var sin6 = UnsafeRawPointer(addrPtr).load(as: sockaddr_in6.self)
                if inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    let address = String(cString: buffer)
                    if !address.isEmpty {
                        results.append(NetworkInterface(
                            name: name,
                            address: address,
                            isIPv4: false,
                            isUp: isUp,
                            isLoopback: isLoopback
                        ))
                    }
                }
            }
        }

        return results
    }
}

public struct IPResolutionResult: Equatable, Sendable {
    public let host: String
    public let interfaceName: String

    public init(host: String, interfaceName: String) {
        self.host = host
        self.interfaceName = interfaceName
    }
}

public enum StreamURLError: Error, Equatable, Sendable, LocalizedError {
    case noWiFiIPv4Address

    public var errorDescription: String? {
        switch self {
        case .noWiFiIPv4Address:
            return "No Wi-Fi network address. Connect to Wi-Fi to mirror."
        }
    }
}
public struct NetworkInterfaceHelper: Sendable {
    public static let shared = NetworkInterfaceHelper()
    public let provider: any NetworkInterfaceProvider

    public init(provider: any NetworkInterfaceProvider = SystemNetworkInterfaceProvider()) {
        self.provider = provider
    }

    public func getInterfaces() -> [NetworkInterface] {
        provider.getInterfaces()
    }

    public func getIPv4Address(for interfaceName: String = "en0") -> String? {
        let matching = provider.getInterfaces().first { iface in
            iface.name == interfaceName && iface.isIPv4 && iface.isUp && (!iface.isLoopback || interfaceName.hasPrefix("lo"))
        }
        return matching?.address
    }

    public func getFirstNonLoopbackIPv4Address() -> (interfaceName: String, address: String)? {
        if let matching = provider.getInterfaces().first(where: { !$0.isLoopback && $0.isIPv4 && $0.isUp }) {
            return (interfaceName: matching.name, address: matching.address)
        }
        return nil
    }

    /// Resolves the address a TV or browser should use. Throws when the phone has no
    /// usable non-loopback IPv4 address; never falls back to localhost.
    public func resolveStreamIP(preferredInterface: String = "en0") throws -> IPResolutionResult {
        if let ip = getIPv4Address(for: preferredInterface) {
            return IPResolutionResult(host: ip, interfaceName: preferredInterface)
        }
        if let alt = getFirstNonLoopbackIPv4Address() {
            return IPResolutionResult(host: alt.address, interfaceName: alt.interfaceName)
        }
        throw StreamURLError.noWiFiIPv4Address
    }
    public static func formatStreamURL(host: String, port: UInt16, path: String = "view") -> String {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let formattedHost = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        return "http://\(formattedHost):\(port)/\(cleanPath)"
    }

    public func resolveStreamURL(
        port: UInt16,
        preferredInterface: String = "en0",
        path: String = "view"
    ) throws -> (url: String, resolution: IPResolutionResult) {
        let resolution = try resolveStreamIP(preferredInterface: preferredInterface)
        let url = Self.formatStreamURL(host: resolution.host, port: port, path: path)
        return (url, resolution)
    }
}
