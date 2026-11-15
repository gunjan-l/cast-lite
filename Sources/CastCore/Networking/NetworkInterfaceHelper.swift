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
    public let isFallback: Bool
    public let interfaceName: String?
    public let warningMessage: String?

    public init(
        host: String,
        isFallback: Bool,
        interfaceName: String? = nil,
        warningMessage: String? = nil
    ) {
        self.host = host
        self.isFallback = isFallback
        self.interfaceName = interfaceName
        self.warningMessage = warningMessage
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

    public func resolveStreamIP(
        preferredInterface: String = "en0",
        fallbackHost: String = "localhost",
        fallbackToAnyNonLoopback: Bool = false
    ) -> IPResolutionResult {
        if let ip = getIPv4Address(for: preferredInterface) {
            return IPResolutionResult(
                host: ip,
                isFallback: false,
                interfaceName: preferredInterface,
                warningMessage: nil
            )
        } else if fallbackToAnyNonLoopback, let alt = getFirstNonLoopbackIPv4Address() {
            return IPResolutionResult(
                host: alt.address,
                isFallback: false,
                interfaceName: alt.interfaceName,
                warningMessage: nil
            )
        } else {
            return IPResolutionResult(
                host: fallbackHost,
                isFallback: true,
                interfaceName: nil,
                warningMessage: "Wi-Fi is disconnected. Mirroring is only accessible locally on this device via \(fallbackHost)."
            )
        }
    }

    public static func formatStreamURL(host: String, port: UInt16, path: String = "view") -> String {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let formattedHost = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        return "http://\(formattedHost):\(port)/\(cleanPath)"
    }

    public func resolveStreamURL(
        port: UInt16,
        preferredInterface: String = "en0",
        fallbackHost: String = "localhost",
        path: String = "view"
    ) -> (url: String, resolution: IPResolutionResult) {
        let resolution = resolveStreamIP(
            preferredInterface: preferredInterface,
            fallbackHost: fallbackHost,
            fallbackToAnyNonLoopback: true
        )
        let url = Self.formatStreamURL(host: resolution.host, port: port, path: path)
        return (url, resolution)
    }
}
