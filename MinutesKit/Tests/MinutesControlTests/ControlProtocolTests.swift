import Foundation
import Testing
@testable import MinutesControl

struct ControlProtocolTests {
    private func parse(_ text: String) -> Result<ControlRequest, ControlFailure> { ControlRequest.parse(Data(text.utf8)) }

    @Test("A well-formed request keeps its id, method and params")
    func parsesRequest() throws {
        let request = try parse(#"{"id": 7, "method": "start", "params": {"title": "Standup"}}"#).get()
        #expect(request.id == .number(7))
        #expect(request.method == "start")
        #expect(request.params["title"] == .string("Standup"))
        let stringID = try parse(#"{"id": "abc", "method": "status"}"#).get()
        #expect(stringID.id == .string("abc"))
        #expect(stringID.params.isEmpty)
    }

    @Test("Malformed requests become bad_request, keeping any readable id")
    func rejectsMalformed() {
        for text in ["not json", "[1,2]", "42", #"{"id": 1}"#, #"{"id": 1, "method": 5}"#, #"{"id": 1, "method": "status", "params": [1]}"#] {
            guard case .failure(let failure) = parse(text) else { Issue.record("accepted \(text)"); continue }
            #expect(failure.error.code == .badRequest)
        }
        guard case .failure(let failure) = parse(#"{"id": "x", "method": ""}"#) else { Issue.record("accepted empty method"); return }
        #expect(failure.id == .string("x"))
    }

    @Test("Oversized lines are refused before parsing")
    func refusesOversized() {
        let big = Data(repeating: 0x20, count: ControlRequest.maximumLineBytes + 1)
        guard case .failure(let failure) = ControlRequest.parse(big) else { Issue.record("accepted"); return }
        #expect(failure.error.code == .badRequest)
    }

    @Test("Responses have the contract shape and round-trip")
    func responseShape() throws {
        let ok = ControlResponse(id: 3, result: ["meeting_id": "m1"])
        let okJSON = try JSONValue.decode(ok.encodedLine().dropLast())
        #expect(okJSON == ["id": 3, "ok": true, "result": ["meeting_id": "m1"]])
        #expect(ok.encodedLine().last == 0x0A)
        #expect(String(decoding: ok.encodedLine(), as: UTF8.self).contains(#""id":3"#))

        let failed = ControlResponse(id: "a", error: ControlError(.wrongMeeting, "Another meeting is recording"))
        let failedJSON = try JSONValue.decode(failed.encodedLine().dropLast())
        #expect(failedJSON == ["id": "a", "ok": false, "error": ["code": "wrong_meeting", "message": "Another meeting is recording"]])
        #expect(try ControlResponse.decode(failed.encodedLine().dropLast()) == failed)
    }

    @Test("Every error code has its contract name")
    func errorCodes() {
        #expect(ControlErrorCode.allCases.map(\.rawValue) == ["bad_request", "unknown_method", "busy", "not_ready", "permission_denied",
                                                              "not_recording", "wrong_meeting", "not_found", "internal"])
    }

    @Test("start params: title required, system audio by default, microphone refused")
    func startParams() throws {
        let defaults = try ControlStartParams(params: ["title": "  Weekly  "])
        #expect(defaults == ControlStartParams(title: "Weekly", captureMode: .systemAudio))
        let full = try ControlStartParams(params: ["title": "Call", "capture_mode": "system_and_microphone", "event_id": "evt",
            "attendees": [["name": "Ana", "email": "ana@example.com"], ["email": "bo@example.com"]]])
        #expect(full.captureMode == .systemAndMicrophone)
        #expect(full.eventID == "evt")
        #expect(full.attendees == [ControlAttendee(name: "Ana", email: "ana@example.com"), ControlAttendee(name: nil, email: "bo@example.com")])

        let invalid: [[String: JSONValue]] = [
            [:], ["title": ""], ["title": 3],
            ["title": "x", "capture_mode": "microphone"], ["title": "x", "capture_mode": "taps"],
            ["title": "x", "attendees": "Ana"], ["title": "x", "attendees": [["phone": "1"]]], ["title": "x", "attendees": [5]]
        ]
        for params in invalid {
            #expect(throws: ControlError.self) { try ControlStartParams(params: params) }
        }
    }

    @Test("assign params: ids and name required, learn must be boolean")
    func assignParams() throws {
        let params = try ControlAssignParams(params: ["meeting_id": "m", "cluster_id": "c", "name": "Ana", "email": "ana@x.com", "learn": true])
        #expect(params == ControlAssignParams(meetingID: "m", clusterID: "c", name: "Ana", email: "ana@x.com", learn: true))
        #expect(try ControlAssignParams(params: ["meeting_id": "m", "cluster_id": "c", "name": "Ana"]).learn == false)
        do { _ = try ControlAssignParams(params: ["meeting_id": "m", "cluster_id": "c", "name": "Ana", "learn": "yes"]); Issue.record("accepted") }
        catch { #expect(error.code == .badRequest) }
        #expect(throws: ControlError.self) { try ControlAssignParams(params: ["meeting_id": "m", "name": "Ana"]) }
        #expect(throws: ControlError.self) { try ControlMeetingParams(params: ["meeting_id": 1]) }
        #expect(try ControlMarkParams(params: [:]).label == nil)
    }

    @Test("Line framing splits lines, strips CR, skips blanks and caps length")
    func framing() {
        var framer = LineFramer(limit: 8)
        #expect(framer.append(Data("ab\r\n\n  \ncd".utf8)) == [.line(Data("ab".utf8))])
        #expect(framer.append(Data("e\n".utf8)) == [.line(Data("cde".utf8))])
        #expect(framer.append(Data("123456789".utf8)) == [.overflow])
        var other = LineFramer(limit: 4)
        #expect(other.append(Data("12345\n".utf8)) == [.overflow])
    }

    @Test("The socket path honours MINUTES_CONTROL_SOCKET")
    func socketPath() {
        #expect(ControlSocketPath.resolve(environment: ["MINUTES_CONTROL_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(ControlSocketPath.resolve(environment: [:]).hasSuffix("Library/Application Support/Minutes/control.sock"))
    }
}
