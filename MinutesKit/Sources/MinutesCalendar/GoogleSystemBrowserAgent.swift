import AuthenticationServices
import Foundation
import MinutesCore
#if os(macOS)
import AppKit
import Darwin
#else
import UIKit
#endif

/// Retain this object for the duration of sign-in. Calling connect is the only action that opens a browser.
@MainActor public final class GoogleSystemBrowserAgent: NSObject, GoogleOAuthUserAgent {
    public var platform: GoogleOAuthPlatform {
        #if os(macOS)
        .desktop
        #else
        .iOS
        #endif
    }
    private let anchor: ASPresentationAnchor?
    #if os(macOS)
    private var loopback: GoogleLoopbackReceiver?
    #endif
    public init(anchor: ASPresentationAnchor? = nil) { self.anchor = anchor }
    public func prepareRedirect(configuration: GoogleCalendarConfiguration) async throws -> URL {
        #if os(macOS)
        let receiver = try GoogleLoopbackReceiver()
        loopback = receiver
        return receiver.redirectURI
        #else
        _ = try configuration.clientID(for: .iOS)
        guard let scheme = configuration.iOSCallbackScheme, let url = URL(string: scheme + ":/oauth2redirect") else { throw OAuthError.invalidConfiguration }
        return url
        #endif
    }
    public func authorize(url: URL, redirectURI: URL) async throws -> URL {
        #if os(macOS)
        guard let receiver = loopback else { throw OAuthError.invalidConfiguration }
        defer { receiver.cancel(); loopback = nil }
        // Desktop OAuth clients use a loopback redirect, as required by Google's installed-app policy.
        guard NSWorkspace.shared.open(url) else { throw OAuthError.presentationUnavailable }
        guard let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { throw OAuthError.invalidConfiguration }
        return try await withTaskCancellationHandler { try await receiver.receive(expectedState: state) } onCancel: { receiver.cancel() }
        #else
        let browser = OAuthSystemBrowserSession(anchor: anchor)
        return try await browser.authorize(url: url, callbackScheme: redirectURI.scheme!)
        #endif
    }
}

#if os(macOS)
/// Binds only the IPv4 loopback interface on an OS-assigned port. No callback value is printed or persisted.
final class GoogleLoopbackReceiver: @unchecked Sendable {
    let redirectURI: URL
    private let lock = NSLock()
    private var descriptor: Int32
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.presentationUnavailable }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw OAuthError.presentationUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard found == 0 else { close(fd); throw OAuthError.presentationUnavailable }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        descriptor = fd
        redirectURI = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/")!
    }
    deinit { cancel() }
    func cancel() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }
    func receive(expectedState: String) async throws -> URL {
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
#endif
