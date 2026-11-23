import Foundation

/// A stdio MCP server (JSON-RPC 2.0, one message per line) whose tools relay
/// to the Minutes control socket. Protocol handling is separate from I/O so it
/// can be tested without a process.
public struct MCPServer: Sendable {
    public typealias Relay = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> ControlResponse

    public static let defaultProtocolVersion = "2025-06-18"
    public let version: String
    private let relay: Relay

    public init(version: String = "1.0.0", relay: @escaping Relay) {
        self.version = version
        self.relay = relay
    }

    /// Relays through a socket client; each call is a fresh connection.
    public init(version: String = "1.0.0", client: ControlSocketClient) {
        self.init(version: version) { method, params in
            let request = ControlRequest(id: .string(UUID().uuidString), method: method, params: params)
            return try await Task.detached { try client.send(request) }.value
        }
    }

    public struct Tool: Sendable {
        public let name: String
        public let method: ControlMethod
        public let description: String
        public let inputSchema: JSONValue
    }

    private static let meetingID: JSONValue = ["type": "string", "description": "The meeting id returned by minutes_start or minutes_status."]

    public static let tools: [Tool] = [
        Tool(name: "minutes_status", method: .status,
             description: "Report whether Minutes is recording (meeting id, the capture mode actually in use, duration), whether it is processing, whether it is ready to record and why not, the Screen & System Audio permission, the default audio devices and the app version.",
             inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]),
        Tool(name: "minutes_start", method: .start,
             description: "Start recording a meeting. Returns only once capture has actually started. Never falls back to microphone-only: fails with permission_denied when system audio cannot be captured, busy when a recording is active or processing, not_ready when models, consent or speech recognition are not ready.",
             inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Meeting title stored on the recording."],
                    "capture_mode": ["type": "string", "enum": ["system_audio", "system_and_microphone"], "default": "system_audio",
                                     "description": "system_audio records Mac audio only; system_and_microphone adds the microphone as a separate track."],
                    "event_id": ["type": "string", "description": "Calendar event id to store on the meeting (optional)."],
                    "attendees": ["type": "array", "description": "Invitees, used as context for speaker naming only.",
                                  "items": ["type": "object", "properties": ["name": ["type": "string"], "email": ["type": "string"]], "additionalProperties": false]]
                ],
                "required": ["title"], "additionalProperties": false
             ]),
        Tool(name: "minutes_stop", method: .stop,
             description: "Stop the active recording. Returns once audio is finalized and processing has started; processing continues in the background (poll minutes_status / minutes_get).",
             inputSchema: ["type": "object", "properties": ["meeting_id": meetingID], "required": ["meeting_id"], "additionalProperties": false]),
        Tool(name: "minutes_mark", method: .mark,
             description: "Mark the current moment of the active recording, with an optional label.",
             inputSchema: ["type": "object", "properties": ["label": ["type": "string", "description": "Short label for the moment (default \"Key moment\")."]], "additionalProperties": false]),
        Tool(name: "minutes_get", method: .get,
             description: "Fetch a meeting: its metadata and status, speaker clusters (id, track, label, speech seconds, assignment, person, confidence) and utterances (cluster, speaker name, start/end seconds, text).",
             inputSchema: ["type": "object", "properties": ["meeting_id": meetingID], "required": ["meeting_id"], "additionalProperties": false]),
        Tool(name: "minutes_assign", method: .assign,
             description: "Name a speaker cluster: assigns the person (found by email, else by name, else created), renames that cluster's utterances, rewrites generic labels in the summary and refreshes the vault note. learn=true also remembers the voice (needs a trained-model cluster with at least 20 s of speech).",
             inputSchema: [
                "type": "object",
                "properties": [
                    "meeting_id": meetingID,
                    "cluster_id": ["type": "string", "description": "Cluster id from minutes_get."],
                    "name": ["type": "string", "description": "The person's display name."],
                    "email": ["type": "string", "description": "The person's email (optional; used to match an existing person)."],
                    "learn": ["type": "boolean", "default": false, "description": "Also remember this voice for future meetings."]
                ],
                "required": ["meeting_id", "cluster_id", "name"], "additionalProperties": false
             ]),
        Tool(name: "minutes_export", method: .export,
             description: "Save the meeting's transcript, summary and notes to the connected Parachute vault, updating the earlier note if there is one.",
             inputSchema: ["type": "object", "properties": ["meeting_id": meetingID], "required": ["meeting_id"], "additionalProperties": false]),
        Tool(name: "minutes_clip", method: .clip,
             description: "Write a short audio clip of one speaker cluster (its clearest, non-overlapping speech in time order, 0.25 s silence between segments) as a mono AAC .m4a on this Mac. Returns the file path, its duration and the source segments (start/end seconds, text). Files are deleted after 7 days.",
             inputSchema: [
                "type": "object",
                "properties": [
                    "meeting_id": meetingID,
                    "cluster_id": ["type": "string", "description": "Cluster id from minutes_get."],
                    "max_seconds": ["type": "number", "minimum": 3, "maximum": 20, "default": 10, "description": "Longest clip length in seconds."]
                ],
                "required": ["meeting_id", "cluster_id"], "additionalProperties": false
             ])
    ]

    private static let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    /// Handles one incoming line; nil means no reply (a notification).
    public func handle(line: Data) async -> Data? {
        guard let message = try? JSONValue.decode(line) else {
            return Self.encode(Self.errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        guard let reply = await handle(message: message) else { return nil }
        return Self.encode(reply)
    }

    public func handle(message: JSONValue) async -> JSONValue? {
        guard case .object(let object) = message else {
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid Request")
        }
        let id = object["id"]
        guard case .string(let method)? = object["method"] else {
            // A response from the client (we never send requests) or garbage.
            return id == nil ? nil : Self.errorResponse(id: id ?? .null, code: -32600, message: "Invalid Request")
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id else { return nil } // Notifications, including notifications/initialized.
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.defaultProtocolVersion
            return Self.success(id: id, result: [
                "protocolVersion": .string(requested),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "minutes-mcp", "version": .string(version)],
                "instructions": "Controls the Minutes app on this Mac through its local control socket. Enable it with: defaults write ai.nosaas.minutes controlSocketEnabled -bool true"
            ])
        case "ping":
            return Self.success(id: id, result: [:])
        case "tools/list":
            return Self.success(id: id, result: ["tools": .array(Self.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })])
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = Self.toolsByName[name] else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(params["name"]?.stringValue ?? "(none)")")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let value)?: arguments = value
            default: return Self.errorResponse(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            return Self.success(id: id, result: await call(tool, arguments: arguments))
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ tool: Tool, arguments: [String: JSONValue]) async -> JSONValue {
        do {
            let response = try await relay(tool.method.rawValue, arguments)
            switch response.outcome {
            case .success(let result):
                return ["content": [["type": "text", "text": .string(result.encodedString())]], "isError": false]
            case .failure(let error):
                return Self.toolError(code: error.code.rawValue, message: error.message)
            }
        } catch let error as ControlError {
            return Self.toolError(code: error.code.rawValue, message: error.message)
        } catch {
            return Self.toolError(code: "unavailable",
                message: "Could not reach Minutes (\(error.localizedDescription)). Is Minutes running with controlSocketEnabled?")
        }
    }

    private static func toolError(code: String, message: String) -> JSONValue {
        let body: JSONValue = ["error": ["code": .string(code), "message": .string(message)]]
        return ["content": [["type": "text", "text": .string(body.encodedString())]], "isError": true]
    }

    private static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private static func encode(_ value: JSONValue) -> Data {
        var data = (try? value.encodedLine()) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
