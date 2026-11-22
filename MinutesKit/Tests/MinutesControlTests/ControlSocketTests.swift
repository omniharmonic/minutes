import Foundation
import Testing
@testable import MinutesControl

/// A short path: Unix socket paths are limited to 104 bytes.
func temporarySocketPath() -> String {
    "/tmp/mc-\(UUID().uuidString.prefix(8)).sock"
}

/// Sends raw bytes and reads `count` response lines on one connection.
func rawExchange(path: String, _ payload: String, lines count: Int) throws -> [JSONValue] {
    let fd = try ControlSocketClient(path: path, timeout: 5).connect()
    defer { close(fd) }
    _ = payload.withCString { write(fd, $0, strlen($0)) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while received.filter({ $0 == 0x0A }).count < count {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return try received.split(separator: 0x0A).map { try JSONValue.decode(Data($0)) }
}

@Suite(.serialized) struct ControlSocketTests {
    private static func echoServer(path: String) -> ControlSocketServer {
        ControlSocketServer(path: path) { request in
            if request.method == "echo" { return ControlResponse(id: request.id, result: .object(request.params)) }
            return ControlResponse(id: request.id, error: ControlError(.unknownMethod, "No method \(request.method)"))
        }
    }

    @Test("The socket is created 0600 and removed on stop")
    func permissions() throws {
        let path = temporarySocketPath()
        let server = Self.echoServer(path: path)
        try server.start()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFSOCK)
        #expect((info.st_mode & 0o777) == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("One connection carries several requests, answered in order")
    func multipleRequests() throws {
        let path = temporarySocketPath()
        let server = Self.echoServer(path: path)
        try server.start(); defer { server.stop() }
        let replies = try rawExchange(path: path, #"{"id":1,"method":"echo","params":{"a":1}}"# + "\n" + #"{"id":"two","method":"nope"}"# + "\n", lines: 2)
        #expect(replies.count == 2)
        #expect(replies[0] == ["id": 1, "ok": true, "result": ["a": 1]])
        #expect(replies[1]["id"] == "two")
        #expect(replies[1]["error"]?["code"] == "unknown_method")
    }

    @Test("Malformed lines get bad_request and the connection stays usable")
    func malformedInput() throws {
        let path = temporarySocketPath()
        let server = Self.echoServer(path: path)
        try server.start(); defer { server.stop() }
        let replies = try rawExchange(path: path, "{nope\n\u{01}\u{02}garbage\n" + #"{"id":9,"method":"echo"}"# + "\n", lines: 3)
        try #require(replies.count == 3)
        #expect(replies[0]["error"]?["code"] == "bad_request")
        #expect(replies[1]["error"]?["code"] == "bad_request")
        #expect(replies[2]["ok"] == true)
    }

    @Test("An oversized request is refused and the server keeps serving")
    func oversized() throws {
        let path = temporarySocketPath()
        let server = Self.echoServer(path: path)
        try server.start(); defer { server.stop() }
        let huge = String(repeating: "x", count: ControlRequest.maximumLineBytes + 10)
        let replies = try rawExchange(path: path, huge, lines: 1)
        #expect(replies.first?["error"]?["code"] == "bad_request")
        let after = try ControlSocketClient(path: path, timeout: 5).send(ControlRequest(id: 1, method: "echo"))
        #expect(after.outcome == .success([:]))
    }

    @Test("A stale socket file is replaced; a live server is not")
    func staleSocket() throws {
        let path = temporarySocketPath()
        let first = Self.echoServer(path: path)
        try first.start()
        let second = Self.echoServer(path: path)
        #expect(throws: ControlSocketError.inUse(path)) { try second.start() }
        first.stop()

        // Leave a dead socket file behind, as a crash would.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        let third = Self.echoServer(path: path)
        try third.start(); defer { third.stop() }
        #expect(try ControlSocketClient(path: path, timeout: 5).send(ControlRequest(id: 2, method: "echo")).id == 2)
    }

    @Test("The client reports a missing server as a connection error")
    func noServer() {
        #expect(throws: ControlSocketError.self) { try ControlSocketClient(path: temporarySocketPath(), timeout: 1).send(ControlRequest(id: 1, method: "status")) }
    }
}
