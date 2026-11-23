import Foundation

/// Error codes of the control socket. The names are a contract with external clients.
public enum ControlErrorCode: String, Sendable, CaseIterable {
    case badRequest = "bad_request"
    case unknownMethod = "unknown_method"
    case busy
    case notReady = "not_ready"
    case permissionDenied = "permission_denied"
    case notRecording = "not_recording"
    case wrongMeeting = "wrong_meeting"
    case notFound = "not_found"
    case `internal`
}

public struct ControlError: Error, Sendable, Equatable, LocalizedError {
    public let code: ControlErrorCode
    public let message: String
    public init(_ code: ControlErrorCode, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code.rawValue): \(message)" }

    public static func badRequest(_ message: String) -> ControlError { ControlError(.badRequest, message) }
}

public enum ControlMethod: String, Sendable, CaseIterable {
    case status, start, stop, mark, get, assign, export, clip
}

/// One request line: `{"id": <any>, "method": "<name>", "params": {...}}`.
public struct ControlRequest: Sendable, Equatable {
    public let id: JSONValue
    public let method: String
    public let params: [String: JSONValue]

    public init(id: JSONValue, method: String, params: [String: JSONValue] = [:]) {
        self.id = id; self.method = method; self.params = params
    }

    /// Requests longer than this are refused before they are parsed.
    public static let maximumLineBytes = 1 << 20

    /// Parses one line. A failure keeps whatever id could be read, so the
    /// client can still match the error to its request.
    public static func parse(_ line: Data) -> Result<ControlRequest, ControlFailure> {
        guard line.count <= maximumLineBytes else {
            return .failure(ControlFailure(id: .null, error: .badRequest("Request exceeds \(maximumLineBytes) bytes")))
        }
        guard let value = try? JSONValue.decode(line) else {
            return .failure(ControlFailure(id: .null, error: .badRequest("Request is not valid JSON")))
        }
        guard case .object(let object) = value else {
            return .failure(ControlFailure(id: .null, error: .badRequest("Request must be a JSON object")))
        }
        let id = object["id"] ?? .null
        guard case .string(let method)? = object["method"], !method.isEmpty else {
            return .failure(ControlFailure(id: id, error: .badRequest("Request needs a string \"method\"")))
        }
        let params: [String: JSONValue]
        switch object["params"] {
        case nil, .null?: params = [:]
        case .object(let value)?: params = value
        default: return .failure(ControlFailure(id: id, error: .badRequest("\"params\" must be an object")))
        }
        return .success(ControlRequest(id: id, method: method, params: params))
    }

    public func encodedLine() throws -> Data {
        try JSONValue.object(["id": id, "method": .string(method), "params": .object(params)]).encodedLine()
    }
}

public struct ControlFailure: Error, Sendable, Equatable {
    public let id: JSONValue
    public let error: ControlError
    public init(id: JSONValue, error: ControlError) { self.id = id; self.error = error }
}

/// One response line: `{"id", "ok": true, "result"}` or `{"id", "ok": false, "error": {"code", "message"}}`.
public struct ControlResponse: Sendable, Equatable {
    public let id: JSONValue
    public let outcome: Result<JSONValue, ControlError>

    public init(id: JSONValue, result: JSONValue) { self.id = id; self.outcome = .success(result) }
    public init(id: JSONValue, error: ControlError) { self.id = id; self.outcome = .failure(error) }

    public var json: JSONValue {
        switch outcome {
        case .success(let result): ["id": id, "ok": true, "result": result]
        case .failure(let error): ["id": id, "ok": false, "error": ["code": .string(error.code.rawValue), "message": .string(error.message)]]
        }
    }

    public func encodedLine() -> Data {
        var data = (try? json.encodedLine()) ?? Data(#"{"id":null,"ok":false,"error":{"code":"internal","message":"Response could not be encoded"}}"#.utf8)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ControlResponse {
        let value = try JSONValue.decode(line)
        guard let ok = value["ok"]?.boolValue else { throw ControlError(.internal, "Response has no \"ok\" field") }
        let id = value["id"] ?? .null
        if ok { return ControlResponse(id: id, result: value["result"] ?? [:]) }
        let code = value["error"]?["code"]?.stringValue.flatMap(ControlErrorCode.init(rawValue:)) ?? .internal
        let message = value["error"]?["message"]?.stringValue ?? "Unknown error"
        return ControlResponse(id: id, error: ControlError(code, message))
    }
}

// MARK: - Parameters

public enum ControlCaptureMode: String, Sendable, CaseIterable {
    case microphone
    case systemAudio = "system_audio"
    case systemAndMicrophone = "system_and_microphone"
}

public struct ControlAttendee: Sendable, Equatable {
    public let name: String?
    public let email: String?
    public init(name: String?, email: String?) { self.name = name; self.email = email }
}

public struct ControlStartParams: Sendable, Equatable {
    public let title: String
    public let captureMode: ControlCaptureMode
    public let eventID: String?
    public let attendees: [ControlAttendee]

    public init(title: String, captureMode: ControlCaptureMode = .systemAudio, eventID: String? = nil, attendees: [ControlAttendee] = []) {
        self.title = title; self.captureMode = captureMode; self.eventID = eventID; self.attendees = attendees
    }

    public init(params: [String: JSONValue]) throws(ControlError) {
        let title = try ControlParams.requiredString(params, "title")
        let modeName = try ControlParams.optionalString(params, "capture_mode") ?? ControlCaptureMode.systemAudio.rawValue
        // The API records call audio only; microphone-only is not an unattended call recording.
        guard let mode = ControlCaptureMode(rawValue: modeName), mode != .microphone else {
            throw .badRequest("\"capture_mode\" must be \"system_audio\" or \"system_and_microphone\"")
        }
        var attendees: [ControlAttendee] = []
        switch params["attendees"] {
        case nil, .null?: break
        case .array(let items)?:
            for (index, item) in items.enumerated() {
                guard case .object(let entry) = item else { throw .badRequest("\"attendees[\(index)]\" must be an object") }
                let name = try ControlParams.optionalString(entry, "name", label: "attendees[\(index)].name")
                let email = try ControlParams.optionalString(entry, "email", label: "attendees[\(index)].email")
                guard name != nil || email != nil else { throw .badRequest("\"attendees[\(index)]\" needs a name or an email") }
                attendees.append(ControlAttendee(name: name, email: email))
            }
        default: throw .badRequest("\"attendees\" must be an array")
        }
        self.init(title: title, captureMode: mode, eventID: try ControlParams.optionalString(params, "event_id"), attendees: attendees)
    }
}

public struct ControlMeetingParams: Sendable, Equatable {
    public let meetingID: String
    public init(meetingID: String) { self.meetingID = meetingID }
    public init(params: [String: JSONValue]) throws(ControlError) {
        meetingID = try ControlParams.requiredString(params, "meeting_id")
    }
}

public struct ControlMarkParams: Sendable, Equatable {
    public let label: String?
    public init(label: String?) { self.label = label }
    public init(params: [String: JSONValue]) throws(ControlError) {
        label = try ControlParams.optionalString(params, "label")
    }
}

public struct ControlAssignParams: Sendable, Equatable {
    public let meetingID: String
    public let clusterID: String
    public let name: String
    public let email: String?
    public let learn: Bool

    public init(meetingID: String, clusterID: String, name: String, email: String? = nil, learn: Bool = false) {
        self.meetingID = meetingID; self.clusterID = clusterID; self.name = name; self.email = email; self.learn = learn
    }

    public init(params: [String: JSONValue]) throws(ControlError) {
        let learn: Bool
        switch params["learn"] {
        case nil, .null?: learn = false
        case .bool(let value)?: learn = value
        default: throw .badRequest("\"learn\" must be a boolean")
        }
        self.init(meetingID: try ControlParams.requiredString(params, "meeting_id"),
                  clusterID: try ControlParams.requiredString(params, "cluster_id"),
                  name: try ControlParams.requiredString(params, "name"),
                  email: try ControlParams.optionalString(params, "email"), learn: learn)
    }
}

public struct ControlClipParams: Sendable, Equatable {
    public static let defaultMaxSeconds = 10.0
    public static let allowedMaxSeconds: ClosedRange<Double> = 3...20

    public let meetingID: String
    public let clusterID: String
    public let maxSeconds: Double

    public init(meetingID: String, clusterID: String, maxSeconds: Double = defaultMaxSeconds) {
        self.meetingID = meetingID; self.clusterID = clusterID; self.maxSeconds = maxSeconds
    }

    public init(params: [String: JSONValue]) throws(ControlError) {
        let maxSeconds: Double
        switch params["max_seconds"] {
        case nil, .null?: maxSeconds = Self.defaultMaxSeconds
        case .number(let value)? where value.isFinite && Self.allowedMaxSeconds.contains(value): maxSeconds = value
        default: throw .badRequest("\"max_seconds\" must be a number from 3 to 20")
        }
        self.init(meetingID: try ControlParams.requiredString(params, "meeting_id"),
                  clusterID: try ControlParams.requiredString(params, "cluster_id"), maxSeconds: maxSeconds)
    }
}

enum ControlParams {
    /// A present, non-blank string, trimmed.
    static func requiredString(_ params: [String: JSONValue], _ key: String) throws(ControlError) -> String {
        guard let value = try optionalString(params, key) else { throw .badRequest("\"\(key)\" is required") }
        return value
    }

    /// Absent, null or blank is nil; any other non-string is an error.
    static func optionalString(_ params: [String: JSONValue], _ key: String, label: String? = nil) throws(ControlError) -> String? {
        switch params[key] {
        case nil, .null?: return nil
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: throw .badRequest("\"\(label ?? key)\" must be a string")
        }
    }
}
