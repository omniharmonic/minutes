import Foundation
import Darwin

/// Binds only the IPv4 loopback interface on a preferred or OS-assigned port. No callback value is printed or persisted.
public final class OAuthLoopbackReceiver: @unchecked Sendable {
    public let redirectURI: URL
    private let lock = NSLock()
    private var descriptor: Int32
    /// `preferredPort` keeps the redirect stable for servers that match it exactly;
    /// when that port is busy the OS assigns one.
    public init(preferredPort: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.presentationUnavailable }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = preferredPort.bigEndian
        var bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if bound != 0, preferredPort != 0 {
            address.sin_port = 0
            bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw OAuthError.presentationUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard found == 0 else { close(fd); throw OAuthError.presentationUnavailable }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        descriptor = fd
        redirectURI = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/")!
    }
    deinit { cancel() }
    public func cancel() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }
    public func receive(expectedState: String) async throws -> URL {
        try await Task.detached { [self] in
            let fd = lock.withLock { descriptor }
            guard fd >= 0 else { throw OAuthError.cancelled }
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 1000) >= 0 else { throw OAuthError.cancelled }
                if p.revents == 0 { continue }
                let client = lock.withLock { descriptor == fd ? accept(fd, nil, nil) : -1 }
                guard client >= 0 else { throw OAuthError.cancelled }
                defer { close(client) }
                // Darwin inherits the listener's nonblocking flag on accepted sockets.
                // A browser may connect before sending HTTP bytes; wait within the
                // receive timeout instead of closing that connection on EAGAIN.
                let flags = fcntl(client, F_GETFL, 0)
                guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { continue }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = read(client, &bytes, bytes.count)
                guard count > 0, let request = String(bytes: bytes.prefix(count), encoding: .utf8) else { continue }
                let fields = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let target = fields.count == 3 && fields[0] == "GET" ? String(fields[1]) : ""
                let callback = URL(string: target, relativeTo: redirectURI)?.absoluteURL
                let states = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.filter { $0.name == "state" } ?? []
                let valid = target.hasPrefix("/?") && !target.contains("#") && states.count == 1 && states.first?.value == expectedState
                let body = valid ? "Sign-in received. You can return to Minutes." : "Not found."
                let response = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
                response.withCString { pointer in _ = Darwin.send(client, pointer, strlen(pointer), 0) }
                if valid, let callback { return callback }
            }
            throw OAuthError.cancelled
        }.value
    }
}
