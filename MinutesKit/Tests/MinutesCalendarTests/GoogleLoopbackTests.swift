#if os(macOS)
import Foundation
import Darwin
import Testing
@testable import MinutesCalendar
import MinutesCore

struct GoogleLoopbackTests {
    @Test func receivesDelayedBrowserRequest() async throws {
        let receiver = try OAuthLoopbackReceiver()
        defer { receiver.cancel() }
        let listener = Task { try await receiver.receive(expectedState: "fixture-state") }
        let redirect = receiver.redirectURI
        let reply = try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            #expect(fd >= 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(redirect.port!).bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            #expect(result == 0)
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 4, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Browser preconnect and scheduling can delay the HTTP bytes after accept.
            try await Task.sleep(for: .milliseconds(120))
            let request = "GET /?state=fixture-state&code=synthetic-code HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            let sent = request.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            #expect(sent == request.utf8.count)
            var bytes = [UInt8](repeating: 0, count: 2048)
            let count = read(fd, &bytes, bytes.count)
            return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
        }.value
        #expect(reply.contains("200 OK"))
        if !reply.contains("200 OK") { receiver.cancel() }
        let callback = try await listener.value
        #expect(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value == "synthetic-code")
    }
}
#endif
