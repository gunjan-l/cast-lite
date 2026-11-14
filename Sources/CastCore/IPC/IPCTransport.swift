import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor IPCServer {
    public typealias PacketCallback = @Sendable (IPCPacket) -> Void

    private var listeningSocket: Int32 = -1
    private var boundPort: UInt16 = 0
    private var isRunning: Bool = false
    private var onPacketReceived: PacketCallback?
    private var acceptTask: Task<Void, Never>?

    public init() {}

    public func setOnPacketReceived(_ callback: @escaping PacketCallback) {
        self.onPacketReceived = callback
    }

    public func start(port: UInt16 = 0) throws -> UInt16 {
        guard !isRunning else { return boundPort }

        #if os(Linux)
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOTSOCK)
        }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }

        guard listen(sock, 10) == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getSockResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(sock, saPtr, &len)
            }
        }
        if getSockResult == 0 {
            boundPort = UInt16(bigEndian: boundAddr.sin_port)
        } else {
            boundPort = port
        }

        listeningSocket = sock
        isRunning = true

        startAcceptLoop(sock: sock)
        return boundPort
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if listeningSocket >= 0 {
            #if os(Linux)
            shutdown(listeningSocket, Int32(SHUT_RDWR))
            #else
            Darwin.shutdown(listeningSocket, SHUT_RDWR)
            #endif
            close(listeningSocket)
            listeningSocket = -1
        }
        acceptTask?.cancel()
        acceptTask = nil
    }

    private func startAcceptLoop(sock: Int32) {
        acceptTask = Task.detached { [weak self] in
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        accept(sock, saPtr, &clientLen)
                    }
                }

                if clientSock < 0 {
                    guard let self = self, await self.isActive() else { break }
                    continue
                }

                guard let self = self else {
                    close(clientSock)
                    break
                }

                Task.detached {
                    await self.handleClientConnection(socket: clientSock)
                }
            }
        }
    }

    private func isActive() -> Bool {
        return isRunning && listeningSocket >= 0
    }

    private func handleClientConnection(socket: Int32) async {
        defer {
            close(socket)
        }

        var incomingData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        while isRunning {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { break }

            incomingData.append(buffer, count: bytesRead)

            while incomingData.count >= 18 {
                let payloadLength: UInt32 = incomingData.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 14, as: UInt32.self).bigEndian
                }
                let totalPacketLength = 18 + Int(payloadLength)
                guard incomingData.count >= totalPacketLength else {
                    break // Wait for more data
                }

                let packetData = incomingData.subdata(in: 0..<totalPacketLength)
                incomingData.removeSubrange(0..<totalPacketLength)

                if let packet = IPCPacket.deserialize(from: packetData) {
                    onPacketReceived?(packet)
                }
            }
        }
    }
}

public actor IPCClient {
    private var socketFd: Int32 = -1
    public private(set) var isConnected: Bool = false

    public init() {}

    public func connect(port: UInt16) throws -> Bool {
        #if os(Linux)
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOTSOCK)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                posixConnect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectResult == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        socketFd = sock
        isConnected = true
        return true
    }

    public func send(packet: IPCPacket) throws {
        guard isConnected, socketFd >= 0 else {
            throw POSIXError(.ENOTCONN)
        }

        let data = packet.serialize()
        try data.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = posixSend(socketFd, baseAddr.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 {
                    throw POSIXError(.EIO)
                }
                totalSent += sent
            }
        }
    }

    public func disconnect() {
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        isConnected = false
    }
}

private func posixConnect(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    return connect(fd, sa, len)
}

private func posixSend(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int, _ flags: Int32) -> Int {
    #if os(Linux)
    return send(fd, buf, len, flags)
    #else
    return Darwin.send(fd, buf, len, flags)
    #endif
}
