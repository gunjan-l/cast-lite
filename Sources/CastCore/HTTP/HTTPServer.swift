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
    private var routes: [String: RouteHandler] = [:]
    private var fallbackHandler: RouteHandler?
    private var acceptTask: Task<Void, Never>?

    public init(port: UInt16 = 8080) {
        self.requestedPort = port
    }

    public func registerRoute(path: String, handler: @escaping RouteHandler) {
        routes[path] = handler
    }

    public func setFallbackHandler(_ handler: @escaping RouteHandler) {
        self.fallbackHandler = handler
    }

    public func start() throws -> UInt16 {
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
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }

        guard listen(sock, 64) == 0 else {
            close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        // Determine actual bound port
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
            boundPort = requestedPort
        }

        listeningSocket = sock
        isRunning = true

        startAcceptLoop()
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

    private func startAcceptLoop() {
        let sock = listeningSocket
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
                    await self.handleClient(socket: clientSock)
                }
            }
        }
    }

    private func isActive() -> Bool {
        return isRunning && listeningSocket >= 0
    }

    private func handleClient(socket: Int32) async {
        defer {
            close(socket)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let requestData = Data(buffer[0..<bytesRead])
        guard let request = HTTPRequestParser.parse(data: requestData) else {
            let badReq = HTTPResponse(statusCode: 400, statusText: "Bad Request", body: Data("Bad Request".utf8))
            _ = sendResponse(socket: socket, response: badReq)
            return
        }

        // Clean path without query items
        let cleanPath = request.path.components(separatedBy: "?").first ?? request.path
        let response: HTTPResponse
        if let handler = routes[cleanPath] {
            response = await handler(request)
        } else if let fallback = fallbackHandler {
            response = await fallback(request)
        } else {
            response = HTTPResponse.notFound()
        }

        _ = sendResponse(socket: socket, response: response)
    }

    private func sendResponse(socket: Int32, response: HTTPResponse) -> Bool {
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
