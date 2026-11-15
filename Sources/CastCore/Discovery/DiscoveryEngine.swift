import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol SSDPTransport: Sendable {
    func bind(port: UInt16) throws -> UInt16
    func sendMulticast(data: Data, toHost: String, port: UInt16) throws
    func receive() throws -> (data: Data, senderIP: String, senderPort: UInt16)?
    func close()
}

public final class DefaultSSDPTransport: SSDPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var isClosed = false
    private let networkHelper: NetworkInterfaceHelper

    public init() {
        self.networkHelper = .shared
    }

    public init(networkHelper: NetworkInterfaceHelper) {
        self.networkHelper = networkHelper
    }

    public func bind(port: UInt16 = 1900) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }

        #if os(Linux)
        let sock = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard sock >= 0 else {
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ENOTSOCK)
        }

        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        #if canImport(Darwin)
        var reusePort: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reusePort, socklen_t(MemoryLayout<Int32>.size))
        #elseif os(Linux)
        var reusePort: Int32 = 1
        setsockopt(sock, SOL_SOCKET, Int32(SO_REUSEPORT), &reusePort, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        // Set receive timeout (500ms) so receive loop can regularly check cancellation
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Attempt binding to requested port, fallback to ephemeral port 0
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                #if canImport(Darwin)
                return Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                #elseif canImport(Glibc)
                return Glibc.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }

        if bindResult != 0 && port != 0 {
            addr.sin_port = 0
            let fallbackResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    #if canImport(Darwin)
                    return Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #elseif canImport(Glibc)
                    return Glibc.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #endif
                }
            }
            if fallbackResult != 0 {
                closeSocket(sock)
                let err = errno
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EADDRINUSE)
            }
        } else if bindResult != 0 {
            closeSocket(sock)
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EADDRINUSE)
        }

        var ifAddr = in_addr()
        if let wifiIP = networkHelper.getIPv4Address(for: "en0") {
            ifAddr.s_addr = inet_addr(wifiIP)
        } else if let alt = networkHelper.getFirstNonLoopbackIPv4Address() {
            ifAddr.s_addr = inet_addr(alt.address)
        } else {
            ifAddr.s_addr = in_addr_t(0)
        }

        #if os(Linux)
        let proto = Int32(IPPROTO_IP)
        #else
        let proto = IPPROTO_IP
        #endif

        // Join SSDP multicast group 239.255.255.250 on the selected interface
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
        mreq.imr_interface = ifAddr
        _ = setsockopt(sock, proto, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        // Pin outgoing multicast packets to chosen network interface
        var multicastIf = ifAddr
        _ = setsockopt(sock, proto, IP_MULTICAST_IF, &multicastIf, socklen_t(MemoryLayout<in_addr>.size))

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundPort = port
        let getSockResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(sock, saPtr, &len)
            }
        }
        if getSockResult == 0 {
            boundPort = UInt16(bigEndian: boundAddr.sin_port)
        }

        self.socketFD = sock
        self.isClosed = false
        return boundPort
    }

    public func sendMulticast(data: Data, toHost: String = "239.255.255.250", port: UInt16 = 1900) throws {
        lock.lock()
        let sock = socketFD
        let closed = isClosed
        lock.unlock()

        guard sock >= 0 && !closed else {
            try sendViaTempSocket(data: data, toHost: toHost, port: port)
            return
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(toHost)

        data.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                    _ = sendto(sock, baseAddr, data.count, 0, destAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func sendViaTempSocket(data: Data, toHost: String, port: UInt16) throws {
        #if os(Linux)
        let sock = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard sock >= 0 else {
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ENOTSOCK)
        }
        defer { closeSocket(sock) }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var ifAddr = in_addr()
        if let wifiIP = networkHelper.getIPv4Address(for: "en0") {
            ifAddr.s_addr = inet_addr(wifiIP)
        } else if let alt = networkHelper.getFirstNonLoopbackIPv4Address() {
            ifAddr.s_addr = inet_addr(alt.address)
        } else {
            ifAddr.s_addr = in_addr_t(0)
        }
        #if os(Linux)
        let proto = Int32(IPPROTO_IP)
        #else
        let proto = IPPROTO_IP
        #endif
        var multicastIf = ifAddr
        _ = setsockopt(sock, proto, IP_MULTICAST_IF, &multicastIf, socklen_t(MemoryLayout<in_addr>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(toHost)

        data.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                    _ = sendto(sock, baseAddr, data.count, 0, destAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func receive() throws -> (data: Data, senderIP: String, senderPort: UInt16)? {
        lock.lock()
        let sock = socketFD
        let closed = isClosed
        lock.unlock()

        guard sock >= 0 && !closed else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
            saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                recvfrom(sock, &buffer, buffer.count, 0, destAddr, &senderLen)
            }
        }

        if bytesRead < 0 {
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                return nil
            }
            if err == EBADF || err == ENOTSOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        guard bytesRead > 0 else { return nil }

        var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &senderAddr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
        let senderIP = String(cString: ipBuffer)
        let senderPort = UInt16(bigEndian: senderAddr.sin_port)
        let data = Data(buffer[0..<bytesRead])

        return (data: data, senderIP: senderIP, senderPort: senderPort)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        if socketFD >= 0 {
            closeSocket(socketFD)
            socketFD = -1
        }
    }

    private func closeSocket(_ sock: Int32) {
        #if canImport(Darwin)
        Darwin.close(sock)
        #elseif canImport(Glibc)
        Glibc.close(sock)
        #endif
    }

    deinit {
        close()
    }
}

public final class MockSSDPTransport: SSDPTransport, @unchecked Sendable {
    private let lock = NSLock()
    public var incomingPackets: [(data: Data, senderIP: String, senderPort: UInt16)] = []
    public var sentPackets: [(data: Data, host: String, port: UInt16)] = []
    public private(set) var isClosed = false
    public var shouldThrowOnReceive = false
    public var boundPort: UInt16

    public init(boundPort: UInt16 = 1900) {
        self.boundPort = boundPort
    }

    public func bind(port: UInt16) throws -> UInt16 {
        return boundPort
    }

    public func sendMulticast(data: Data, toHost: String, port: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        sentPackets.append((data, toHost, port))
    }

    public func receive() throws -> (data: Data, senderIP: String, senderPort: UInt16)? {
        lock.lock()
        defer { lock.unlock() }
        if shouldThrowOnReceive {
            throw POSIXError(.EIO)
        }
        if isClosed || incomingPackets.isEmpty {
            return nil
        }
        return incomingPackets.removeFirst()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
    }

    public func enqueuePacket(data: Data, senderIP: String, senderPort: UInt16 = 1900) {
        lock.lock()
        defer { lock.unlock() }
        incomingPackets.append((data, senderIP, senderPort))
    }

    public func enqueuePacket(text: String, senderIP: String, senderPort: UInt16 = 1900) {
        enqueuePacket(data: Data(text.utf8), senderIP: senderIP, senderPort: senderPort)
    }
}

public actor DiscoveryEngine {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var isSearching: Bool = false
    public private(set) var boundPort: UInt16 = 0

    public static let searchTargets: [String] = [
        "ssdp:all",
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "roku:ecp"
    ]

    private let offlineTimeout: TimeInterval
    private let probeInterval: TimeInterval
    private let transport: SSDPTransport
    private let bonjourProvider: (any BonjourDiscoveryProviding)?
    private var pruneTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var onDevicesChanged: (@Sendable ([DiscoveredDevice]) -> Void)?

    public init(
        offlineTimeout: TimeInterval = 15.0,
        probeInterval: TimeInterval = 4.0,
        transport: SSDPTransport = DefaultSSDPTransport(),
        bonjourProvider: (any BonjourDiscoveryProviding)? = DefaultBonjourDiscoveryProvider()
    ) {
        self.offlineTimeout = offlineTimeout
        self.probeInterval = probeInterval
        self.transport = transport
        self.bonjourProvider = bonjourProvider
    }

    public func setOnDevicesChanged(_ callback: (@Sendable ([DiscoveredDevice]) -> Void)?) {
        self.onDevicesChanged = callback
    }

    public func addOrUpdateDevice(_ device: DiscoveredDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            if !devices[idx].name.isEmpty && devices[idx].name != "Smart TV" && updated.name == "Smart TV" {
                updated.name = devices[idx].name
            }
            devices[idx] = updated
        } else {
            devices.append(device)
        }
        notifyDevicesChanged()
    }

    public func removeDevice(id: String) {
        devices.removeAll(where: { $0.id == id })
        notifyDevicesChanged()
    }

    public func pruneStaleDevices() {
        let now = Date()
        let countBefore = devices.count
        devices.removeAll { now.timeIntervalSince($0.lastSeen) > offlineTimeout }
        if devices.count != countBefore {
            notifyDevicesChanged()
        }
    }

    private func notifyDevicesChanged() {
        let current = self.devices
        onDevicesChanged?(current)
    }

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true

        do {
            self.boundPort = try transport.bind(port: 1900)
        } catch {
            // Transport error during bind handled gracefully
        }

        // Start Bonjour discovery for Chromecast
        bonjourProvider?.startBrowsing { [weak self] device in
            Task { [weak self] in
                await self?.addOrUpdateDevice(device)
            }
        }

        pruneTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self, await self.isSearching else { break }
                await self.pruneStaleDevices()
            }
        }

        let transport = self.transport
        listenerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self, await self.isSearching else { break }
                do {
                    if let (data, senderIP, _) = try transport.receive() {
                        if let packet = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                            await self.processRawSSDPPacket(packet, senderIP: senderIP)
                        }
                    } else {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch {
                    guard await self.isSearching else { break }
                    await self.handleSocketError(error)
                    break
                }
            }
        }

        sendAllSSDPMSearches()

        let intervalNanos = UInt64(probeInterval * 1_000_000_000)
        probeTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard let self = self, await self.isSearching else { break }
                await self.sendAllSSDPMSearches()
            }
        }
    }

    public func stopDiscovery() {
        guard isSearching else { return }
        isSearching = false
        bonjourProvider?.stopBrowsing()
        pruneTask?.cancel()
        pruneTask = nil
        listenerTask?.cancel()
        listenerTask = nil
        probeTask?.cancel()
        probeTask = nil
        transport.close()
    }

    public func handleSocketError(_ error: Error) {
        stopDiscovery()
    }

    public func processRawSSDPPacket(_ packet: String, senderIP: String) {
        if let device = SSDPPacketParser.parse(packet: packet, senderIP: senderIP) {
            addOrUpdateDevice(device)
        }
    }

    public func sendSSDPMSearch(target: String = "ssdp:all") {
        let mSearch = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
        let data = Data(mSearch.utf8)
        try? transport.sendMulticast(data: data, toHost: "239.255.255.250", port: 1900)
    }

    public func sendAllSSDPMSearches() {
        for target in Self.searchTargets {
            sendSSDPMSearch(target: target)
        }
    }
}
