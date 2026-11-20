import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor HTTPServer {
    public typealias RouteHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let requestedPort: UInt16
    private var boundPort: UInt16 = 0
    private var listeningSocket: Int32 = -1
    private var isRunning: Bool = false
    private let state = ServerState()

    public init(port: UInt16 = 8080) {
        self.requestedPort = port
    }

    public func registerRoute(path: String, handler: @escaping RouteHandler) {
        state.setRoute(path, handler)
    }

    public func setFallbackHandler(_ handler: @escaping RouteHandler) {
        state.setFallback(handler)
    }

    public func start() throws -> UInt16 {
        guard !isRunning else { return boundPort }

        // Attempt dual-stack IPv6 socket (binds to both IPv6 and IPv4)
        #if os(Linux)
        let sock6 = socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock6 = socket(AF_INET6, SOCK_STREAM, 0)
        #endif

        if sock6 >= 0 {
            var v6Only: Int32 = 0
            #if os(Linux)
            setsockopt(sock6, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            #else
            setsockopt(sock6, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var opt: Int32 = 1
            setsockopt(sock6, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = requestedPort.bigEndian
            addr6.sin6_addr = in6addr_any

            let bindResult = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(sock6, saPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }

            if bindResult == 0 && listen(sock6, 128) == 0 {
                listeningSocket = sock6
                boundPort = determineBoundPort(sock: sock6, fallback: requestedPort)
                isRunning = true
                state.isRunning = true
                startAcceptLoop()
                return boundPort
            }
            close(sock6)
        }

        // Fallback to standard IPv4 socket
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
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }

        guard listen(sock, 128) == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        listeningSocket = sock
        boundPort = determineBoundPort(sock: sock, fallback: requestedPort)
        isRunning = true
        state.isRunning = true

        startAcceptLoop()
        return boundPort
    }

    private func determineBoundPort(sock: Int32, fallback: UInt16) -> UInt16 {
        var boundAddr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let getSockResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            getsockname(sock, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), &len)
        }
        if getSockResult == 0 {
            if boundAddr.ss_family == sa_family_t(AF_INET6) {
                return withUnsafePointer(to: &boundAddr) { ptr in
                    let sin6 = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr_in6.self)
                    return UInt16(bigEndian: sin6.pointee.sin6_port)
                }
            } else {
                return withUnsafePointer(to: &boundAddr) { ptr in
                    let sin = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr_in.self)
                    return UInt16(bigEndian: sin.pointee.sin_port)
                }
            }
        }
        return fallback
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        state.isRunning = false
        if listeningSocket >= 0 {
            #if os(Linux)
            shutdown(listeningSocket, Int32(SHUT_RDWR))
            #else
            Darwin.shutdown(listeningSocket, SHUT_RDWR)
            #endif
            close(listeningSocket)
            listeningSocket = -1
        }
    }

    private func startAcceptLoop() {
        let sock = listeningSocket
        let state = self.state
        // Accept and per-connection reads block in syscalls, so they run on
        // dispatch threads. The actor only guards start/stop.
        DispatchQueue.global(qos: .userInitiated).async {
            while state.isRunning {
                var clientAddr = sockaddr_storage()
                var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    accept(sock, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), &clientLen)
                }
                if clientSock < 0 {
                    if state.isRunning { continue }
                    break
                }

                var sl = linger(l_onoff: 1, l_linger: 3)
                setsockopt(clientSock, SOL_SOCKET, SO_LINGER, &sl, socklen_t(MemoryLayout<linger>.size))
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                DispatchQueue.global(qos: .userInitiated).async {
                    Self.readRequest(socket: clientSock, state: state)
                }
            }
        }
    }

    private static func closeClient(_ socket: Int32) {
        #if os(Linux)
        shutdown(socket, Int32(SHUT_WR))
        #else
        Darwin.shutdown(socket, SHUT_WR)
        #endif
        close(socket)
    }

    /// Blocking read of the request head. Hands the parsed request to an async task so
    /// route handlers never occupy a dispatch thread.
    private static func readRequest(socket: Int32, state: ServerState) {
        var incomingData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }

            incomingData.append(buffer, count: bytesRead)

            if let string = String(data: incomingData, encoding: .utf8),
               string.contains("\r\n\r\n") || string.contains("\n\n") {
                break
            }

            if incomingData.count >= 65536 { break }
        }

        let requestData = incomingData
        Task.detached {
            await Self.respond(socket: socket, incomingData: requestData, state: state)
        }
    }

    private static func respond(socket: Int32, incomingData: Data, state: ServerState) async {
        defer { closeClient(socket) }

        guard !incomingData.isEmpty, let request = HTTPRequestParser.parse(data: incomingData) else {
            let badReq = HTTPResponse(statusCode: 400, statusText: "Bad Request", body: Data("Bad Request".utf8))
            _ = sendResponse(socket: socket, response: badReq)
            return
        }

        if request.method == "OPTIONS" {
            let optionsResponse = HTTPResponse(
                statusCode: 204,
                statusText: "No Content",
                headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
                    "Access-Control-Allow-Headers": "*"
                ]
            )
            _ = sendResponse(socket: socket, response: optionsResponse)
            return
        }

        let cleanPath = request.path.components(separatedBy: "?").first ?? request.path
        let (route, fallback) = state.handlers(for: cleanPath)
        let response: HTTPResponse
        if let handler = route {
            response = await handler(request)
        } else if let fallback = fallback {
            response = await fallback(request)
        } else {
            response = HTTPResponse.notFound()
        }

        _ = sendResponse(socket: socket, response: response)
    }

    private static func sendResponse(socket: Int32, response: HTTPResponse) -> Bool {
        let serialized = response.serialize()
        return serialized.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return false }
            var totalSent = 0
            while totalSent < serialized.count {
                let sent = send(socket, baseAddr.advanced(by: totalSent), serialized.count - totalSent, 0)
                if sent <= 0 { return false }
                totalSent += sent
            }
            return true
        }
    }
}

/// Lock-guarded state shared with connection threads, which run outside the actor.
private final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: HTTPServer.RouteHandler] = [:]
    private var fallback: HTTPServer.RouteHandler?
    private var running = false

    var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return running }
        set { lock.lock(); defer { lock.unlock() }; running = newValue }
    }

    func setRoute(_ path: String, _ handler: @escaping HTTPServer.RouteHandler) {
        lock.lock(); defer { lock.unlock() }
        routes[path] = handler
    }

    func setFallback(_ handler: @escaping HTTPServer.RouteHandler) {
        lock.lock(); defer { lock.unlock() }
        fallback = handler
    }

    func handlers(for path: String) -> (HTTPServer.RouteHandler?, HTTPServer.RouteHandler?) {
        lock.lock(); defer { lock.unlock() }
        return (routes[path], fallback)
    }
}
