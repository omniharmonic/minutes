import Foundation
#if canImport(Darwin)
import Darwin
#endif
import os

public enum ControlSocketPath {
    public static let environmentKey = "MINUTES_CONTROL_SOCKET"

    /// `~/Library/Application Support/Minutes/control.sock`, or `MINUTES_CONTROL_SOCKET` when set.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[environmentKey], !override.isEmpty { return override }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Minutes/control.sock")
    }
}

public enum ControlSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case inUse(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Control socket path is too long for a Unix socket: \(path)"
        case .inUse(let path): "Another process is already serving \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Fills a `sockaddr_un` for `path`, or nil when it does not fit.
private func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

private func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func disableSigpipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(fd, base + offset, raw.count - offset)
            if written < 0 { if errno == EINTR { continue }; return false }
            offset += written
        }
        return true
    }
}

/// Splits a byte stream into lines, refusing any line longer than the limit.
struct LineFramer {
    let limit: Int
    private(set) var buffer = Data()
    init(limit: Int) { self.limit = limit }

    enum Item: Equatable { case line(Data), overflow }

    mutating func append(_ bytes: Data) -> [Item] {
        buffer.append(bytes)
        var items: [Item] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > limit { items.append(.overflow); return items }
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { items.append(.line(Data(line))) }
        }
        if buffer.count > limit { buffer = Data(); items.append(.overflow) }
        return items
    }
}

/// Holds one async result for a thread that waits on it.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// A newline-delimited JSON server on a Unix domain socket, mode 0600, that
/// only answers connections from the same user. Each connection is served on
/// its own thread; requests on one connection are answered in order.
public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var connections = 0
    private let maximumConnections = 16
    private let log = Logger(subsystem: "app.minutes", category: "control")

    public init(path: String = ControlSocketPath.resolve(), handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listenFD >= 0 && !stopped }

    public func start() throws {
        guard var address = unixAddress(path) else { throw ControlSocketError.pathTooLong(path) }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        try removeStaleSocket()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        disableSigpipe(fd)
        let bound = withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0 else { let code = errno; close(fd); throw ControlSocketError.system("bind", code) }
        // Nobody can connect before listen(), so tightening the mode here leaves no window.
        guard chmod(path, 0o600) == 0 else { let code = errno; close(fd); unlink(path); throw ControlSocketError.system("chmod", code) }
        guard listen(fd, 8) == 0 else { let code = errno; close(fd); unlink(path); throw ControlSocketError.system("listen", code) }
        lock.lock(); listenFD = fd; stopped = false; lock.unlock()
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "Minutes control socket"
        thread.start()
        log.info("Control socket listening")
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        stopped = true; listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        close(fd)
        unlink(path)
        log.info("Control socket stopped")
    }

    deinit { stop() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// A leftover file from a crash is removed; a live server is not replaced.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlSocketError.inUse(path)
        }
        if let probe = try? ControlSocketClient(path: path, timeout: 1).connect() {
            close(probe)
            throw ControlSocketError.inUse(path)
        }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }; if isStopped { break }; continue }
            disableSigpipe(client)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            lock.lock()
            let admitted = connections < maximumConnections
            if admitted { connections += 1 }
            lock.unlock()
            guard admitted else {
                _ = writeAll(client, ControlResponse(id: .null, error: ControlError(.busy, "Too many control connections")).encodedLine())
                close(client); continue
            }
            let thread = Thread { [self] in
                serve(client)
                lock.lock(); connections -= 1; lock.unlock()
            }
            thread.name = "Minutes control connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var framer = LineFramer(limit: ControlRequest.maximumLineBytes)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isStopped {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready == 0 { continue }
            if ready < 0 { if errno == EINTR { continue }; return }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            if count == 0 { return }
            for item in framer.append(Data(chunk[0..<count])) {
                switch item {
                case .overflow:
                    _ = writeAll(fd, ControlResponse(id: .null, error: .badRequest("Request exceeds \(ControlRequest.maximumLineBytes) bytes")).encodedLine())
                    return
                case .line(let line):
                    guard writeAll(fd, respond(to: line).encodedLine()) else { return }
                }
            }
        }
    }

    /// Runs the async handler and waits on this connection's own thread.
    private func respond(to line: Data) -> ControlResponse {
        switch ControlRequest.parse(line) {
        case .failure(let failure): return ControlResponse(id: failure.id, error: failure.error)
        case .success(let request):
            let box = ResultBox<ControlResponse>()
            let done = DispatchSemaphore(value: 0)
            let handler = handler
            Task { box.set(await handler(request)); done.signal() }
            done.wait()
            return box.get() ?? ControlResponse(id: request.id, error: ControlError(.internal, "No response"))
        }
    }
}

/// A blocking client: one request, one response line per call.
public struct ControlSocketClient: Sendable {
    public let path: String
    /// Seconds to wait for a response; stopping a long recording can take a while.
    public let timeout: Int

    public init(path: String = ControlSocketPath.resolve(), timeout: Int = 300) {
        self.path = path; self.timeout = timeout
    }

    func connect() throws -> Int32 {
        guard var address = unixAddress(path) else { throw ControlSocketError.pathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        disableSigpipe(fd)
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else { let code = errno; close(fd); throw ControlSocketError.system("connect", code) }
        return fd
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try connect()
        defer { close(fd) }
        var line = try request.encodedLine()
        line.append(0x0A)
        guard writeAll(fd, line) else { throw ControlSocketError.system("write", errno) }
        var framer = LineFramer(limit: 64 << 20)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw ControlSocketError.system("read", errno) }
            if count == 0 { throw ControlError(.internal, "Minutes closed the connection without answering") }
            for item in framer.append(Data(chunk[0..<count])) {
                if case .line(let data) = item { return try ControlResponse.decode(data) }
                throw ControlError(.internal, "Response too large")
            }
        }
    }
}
