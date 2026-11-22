import Foundation
import Testing
@testable import MinutesControl

@Suite(.serialized) struct MCPServerTests {
    private func call(_ server: MCPServer, _ message: JSONValue) async throws -> JSONValue? {
        guard let data = await server.handle(line: try message.encodedLine()) else { return nil }
        #expect(data.last == 0x0A)
        return try JSONValue.decode(data.dropLast())
    }

    private let offline = MCPServer { _, _ in throw ControlSocketError.system("connect", ENOENT) }

    @Test("initialize echoes the client's protocol version and advertises tools")
    func initialize() async throws {
        let reply = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["serverInfo"]?["name"] == "minutes-mcp")
        let fallback = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": [:]]))
        #expect(fallback["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test("Notifications get no reply; ping and unknown methods are answered")
    func notificationsAndErrors() async throws {
        #expect(try await call(offline, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let ping = try #require(try await call(offline, ["jsonrpc": "2.0", "id": "p", "method": "ping"]))
        #expect(ping == ["jsonrpc": "2.0", "id": "p", "result": [:]])
        let unknown = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"]))
        #expect(unknown["error"]?["code"] == -32601)
        let parse = try #require(await offline.handle(line: Data("{oops".utf8)))
        #expect(try JSONValue.decode(parse.dropLast())["error"]?["code"] == -32700)
    }

    @Test("tools/list names every relayed tool with an object input schema")
    func toolsList() async throws {
        let reply = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"]))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["minutes_status", "minutes_start", "minutes_stop", "minutes_mark",
                                                                  "minutes_get", "minutes_assign", "minutes_export"])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let start = try #require(tools.first { $0["name"] == "minutes_start" })
        #expect(start["inputSchema"]?["required"] == ["title"])
    }

    @Test("tools/call relays to a socket server and returns its result as text")
    func toolsCallThroughSocket() async throws {
        let path = temporarySocketPath()
        let received = Received()
        let socket = ControlSocketServer(path: path) { request in
            received.add(request)
            switch request.method {
            case "status": return ControlResponse(id: request.id, result: ["recording": false, "meeting_id": nil])
            case "stop": return ControlResponse(id: request.id, error: ControlError(.notRecording, "Nothing is recording"))
            default: return ControlResponse(id: request.id, error: ControlError(.unknownMethod, request.method))
            }
        }
        try socket.start(); defer { socket.stop() }
        let server = MCPServer(client: ControlSocketClient(path: path, timeout: 5))

        let status = try #require(try await call(server, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "minutes_status", "arguments": [:]]]))
        #expect(status["result"]?["isError"] == false)
        let text = try #require(status["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONValue.decode(Data(text.utf8)) == ["recording": false, "meeting_id": nil])

        let stop = try #require(try await call(server, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "minutes_stop", "arguments": ["meeting_id": "m1"]]]))
        #expect(stop["result"]?["isError"] == true)
        let errorText = try #require(stop["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONValue.decode(Data(errorText.utf8)) == ["error": ["code": "not_recording", "message": "Nothing is recording"]])
        #expect(received.all.map(\.method) == ["status", "stop"])
        #expect(received.all.last?.params == ["meeting_id": "m1"])
    }

    @Test("Unknown tools are protocol errors; an unreachable app is a tool error")
    func callFailures() async throws {
        let unknown = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "minutes_delete"]]))
        #expect(unknown["error"]?["code"] == -32602)
        let down = try #require(try await call(offline, ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "minutes_status"]]))
        #expect(down["result"]?["isError"] == true)
        #expect(down["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("unavailable") == true)
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ControlRequest] = []
    func add(_ request: ControlRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var all: [ControlRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
