import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol BonjourDiscoveryProviding: Sendable {
    func startBrowsing(
        onDeviceFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onDeviceRemoved: @escaping @Sendable (String) -> Void
    )
    func stopBrowsing()
}

public final class MockBonjourDiscoveryProvider: BonjourDiscoveryProviding, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var isBrowsing = false
    public var onDeviceFound: (@Sendable (DiscoveredDevice) -> Void)?
    public var onDeviceRemoved: (@Sendable (String) -> Void)?

    public init() {}

    public func startBrowsing(
        onDeviceFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onDeviceRemoved: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        isBrowsing = true
        self.onDeviceFound = onDeviceFound
        self.onDeviceRemoved = onDeviceRemoved
    }

    public func stopBrowsing() {
        lock.lock()
        defer { lock.unlock() }
        isBrowsing = false
        onDeviceFound = nil
        onDeviceRemoved = nil
    }

    public func simulateDeviceRemoved(id: String) {
        lock.lock()
        let callback = onDeviceRemoved
        lock.unlock()
        callback?(id)
    }

    public func simulateDeviceFound(_ device: DiscoveredDevice) {
        lock.lock()
        let callback = onDeviceFound
        lock.unlock()
        callback?(device)
    }
}

#if canImport(Darwin)
public final class DefaultBonjourDiscoveryProvider: NSObject, BonjourDiscoveryProviding, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var onDeviceFoundHandler: (@Sendable (DiscoveredDevice) -> Void)?
    private var onDeviceRemovedHandler: (@Sendable (String) -> Void)?
    private var deviceIDsByServiceName: [String: String] = [:]

    public override init() {
        super.init()
    }

    public func startBrowsing(
        onDeviceFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onDeviceRemoved: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        self.onDeviceFoundHandler = onDeviceFound
        self.onDeviceRemovedHandler = onDeviceRemoved
        self.deviceIDsByServiceName.removeAll()
        let oldBrowser = self.browser
        let oldServices = self.resolvingServices
        self.browser = nil
        self.resolvingServices.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            oldBrowser?.stop()
            oldBrowser?.remove(from: .main, forMode: .common)
            oldBrowser?.delegate = nil
            for service in oldServices {
                service.stop()
                service.remove(from: .main, forMode: .common)
                service.delegate = nil
            }

            guard let self = self else { return }
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            self.lock.lock()
            self.browser = browser
            self.lock.unlock()
            browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "")
        }
    }

    public func stopBrowsing() {
        lock.lock()
        self.onDeviceFoundHandler = nil
        self.onDeviceRemovedHandler = nil
        self.deviceIDsByServiceName.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let currentBrowser = self.browser
            let services = self.resolvingServices
            self.browser = nil
            self.resolvingServices.removeAll()
            self.lock.unlock()

            currentBrowser?.stop()
            currentBrowser?.remove(from: .main, forMode: .common)
            currentBrowser?.delegate = nil

            for service in services {
                service.stop()
                service.remove(from: .main, forMode: .common)
                service.delegate = nil
            }
        }
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        lock.lock()
        resolvingServices.append(service)
        lock.unlock()

        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        lock.lock()
        resolvingServices.removeAll { $0 == service }
        let removedID = deviceIDsByServiceName.removeValue(forKey: service.name)
        let callback = onDeviceRemovedHandler
        lock.unlock()

        if let removedID = removedID {
            callback?(removedID)
        }
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        sender.remove(from: .main, forMode: .common)
        sender.delegate = nil

        lock.lock()
        resolvingServices.removeAll { $0 == sender }
        let callback = onDeviceFoundHandler
        lock.unlock()

        guard let callback = callback else { return }
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }

        var resolvedIP: String?
        var resolvedPort: UInt16 = 8009

        for addressData in addresses {
            guard addressData.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let saFamily = addressData.withUnsafeBytes { rawPtr -> sa_family_t in
                rawPtr.load(as: sockaddr.self).sa_family
            }
            if saFamily == sa_family_t(AF_INET) {
                let sin = addressData.withUnsafeBytes { rawPtr in
                    rawPtr.load(as: sockaddr_in.self)
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = sin.sin_addr
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    resolvedIP = String(cString: buffer)
                    resolvedPort = UInt16(bigEndian: sin.sin_port)
                    break
                }
            }
        }

        guard let ip = resolvedIP else { return }

        var friendlyName = sender.name
        if let txtData = sender.txtRecordData() {
            let dict = MDNSParser.parseTXTRecord(data: txtData)
            if let fn = dict["fn"], !fn.isEmpty {
                friendlyName = fn
            } else if let md = dict["md"], !md.isEmpty {
                friendlyName = md
            }
        }

        let device = MDNSParser.parseChromecast(name: friendlyName, ipAddress: ip, port: resolvedPort)
        lock.lock()
        deviceIDsByServiceName[sender.name] = device.id
        lock.unlock()
        callback(device)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.remove(from: .main, forMode: .common)
        sender.delegate = nil
        lock.lock()
        defer { lock.unlock() }
        resolvingServices.removeAll { $0 == sender }
    }
}
#else
public final class DefaultBonjourDiscoveryProvider: BonjourDiscoveryProviding, @unchecked Sendable {
    public init() {}
    public func startBrowsing(
        onDeviceFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onDeviceRemoved: @escaping @Sendable (String) -> Void
    ) {}
    public func stopBrowsing() {}
}
#endif
