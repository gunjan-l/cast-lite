import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor DiscoveryEngine {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var isSearching: Bool = false

    private let offlineTimeout: TimeInterval
    private var pruneTask: Task<Void, Never>?

    public init(offlineTimeout: TimeInterval = 15.0) {
        self.offlineTimeout = offlineTimeout
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
    }

    public func removeDevice(id: String) {
        devices.removeAll(where: { $0.id == id })
    }

    public func pruneStaleDevices() {
        let now = Date()
        devices.removeAll { now.timeIntervalSince($0.lastSeen) > offlineTimeout }
    }

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true

        pruneTask = Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self else { break }
                let searching = await self.isSearching
                guard searching else { break }
                await self.pruneStaleDevices()
            }
        }
    }

    public func stopDiscovery() {
        guard isSearching else { return }
        isSearching = false
        pruneTask?.cancel()
        pruneTask = nil
    }

    public func processRawSSDPPacket(_ packet: String, senderIP: String) {
        if let device = SSDPPacketParser.parse(packet: packet, senderIP: senderIP) {
            addOrUpdateDevice(device)
        }
    }

    public func sendSSDPMSearch() {
        let mSearch = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"

        #if os(Linux)
        let sock = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard sock >= 0 else { return }
        defer { close(sock) }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let data = Data(mSearch.utf8)
        data.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                    _ = sendto(sock, baseAddr, data.count, 0, destAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
