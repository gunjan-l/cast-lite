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
    private var socketFd: Int32 = -1

    public init(offlineTimeout: TimeInterval = 15.0) {
        self.offlineTimeout = offlineTimeout
    }

    public func addOrUpdateDevice(_ device: DiscoveredDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            // Retain custom name if already known
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
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }

    public func processRawSSDPPacket(_ packet: String, senderIP: String) {
        if let device = SSDPPacketParser.parse(packet: packet, senderIP: senderIP) {
            addOrUpdateDevice(device)
        }
    }

    public func sendSSDPMSearch() {
        let mSearch = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: ssdp:all\r
        \r
        """
        // In real network run, sends over UDP 239.255.255.250:1900
        _ = mSearch
    }
}
