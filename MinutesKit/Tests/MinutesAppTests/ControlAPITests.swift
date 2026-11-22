#if os(macOS)
import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesControl
@testable import MinutesApp

@MainActor private final class ControlRecorderFixture: SystemAudioRecording {
    var captureError: String?
    var recoveryNotice: String?
    var capturing = false
    var directory: URL?
    var includedMicrophone: Bool?
    var starts = 0
    func startRecording(to directory: URL, includeMicrophone: Bool) async throws {
        starts += 1
        includedMicrophone = includeMicrophone
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory; capturing = true
    }
    func stopRecording() async throws -> SynchronizedCaptureResult {
        capturing = false
        let root = directory!
        let result = SynchronizedCaptureResult(directory: root, systemAudioURL: root.appendingPathComponent("system.caf"), microphoneURL: nil,
            processingURL: root.appendingPathComponent("mixed.caf"), manifestURL: root.appendingPathComponent("capture.json"), duration: 0.1, issues: [], interruptions: [])
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.01 }
        let file = try AVAudioFile(forWriting: result.processingURL!, settings: format.settings)
        try file.write(from: buffer)
        return result
    }
}

@MainActor @Suite(.serialized) struct ControlAPITests {
    private struct Harness {
        let state: AppState
        let store: MinutesStore
        let recorder: ControlRecorderFixture
        let root: URL
    }

    private func harness(modelsReady: Bool = true, consent: Bool = true,
                         processAudio: @escaping @Sendable (String, URL, DiarizationConfig) async throws -> PipelineResult = { id, _, _ in
                            PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: [], speechDuration: 0)
                         }) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-control-\(UUID())")
        let store = try MinutesStore(dbPath: ":memory:")
        let recorder = ControlRecorderFixture()
        let state = try AppState(store: store, audioDirectory: root, systemRecorder: recorder,
            preferences: try #require(UserDefaults(suiteName: "minutes-control-\(UUID())")),
            recordingModelReadiness: { (modelsReady, modelsReady ? "Fixture models ready" : "Fixture models missing") },
            recordingEnvironmentPreflight: {}, processAudio: processAudio)
        state.recordingConsentAcknowledged = consent
        state.autoFileMeetingsEnabled = false
        state.systemCapturePreflight = { true }
        state.microphoneAuthorized = { true }
        return Harness(state: state, store: store, recorder: recorder, root: root)
    }

    private func send(_ state: AppState, _ method: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await state.handleControlRequest(ControlRequest(id: "t", method: method, params: params))
    }

    private func code(_ response: ControlResponse) -> ControlErrorCode? {
        if case .failure(let error) = response.outcome { return error.code }
        return nil
    }

    private func result(_ response: ControlResponse) throws -> JSONValue {
        switch response.outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    @Test("start refuses when the system audio preflight fails, and never falls back to the microphone")
    func refusesWithoutPermission() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.state.systemCapturePreflight = { false }
        let response = await send(h.state, "start", ["title": "Board call", "capture_mode": "system_and_microphone"])
        #expect(code(response) == .permissionDenied)
        #expect(!h.state.isRecording)
        #expect(h.recorder.starts == 0)
        #expect(h.store.listMeetings().isEmpty)
        #expect(!h.state.isPreparingRecording)

        h.state.systemCapturePreflight = { true }
        h.state.microphoneAuthorized = { false }
        #expect(code(await send(h.state, "start", ["title": "x", "capture_mode": "system_and_microphone"])) == .permissionDenied)
        #expect(h.recorder.starts == 0)
    }

    @Test("start reports not_ready for missing models, consent or speech setup")
    func notReady() async throws {
        let noModels = try harness(modelsReady: false)
        #expect(code(await send(noModels.state, "start", ["title": "x"])) == .notReady)
        let noConsent = try harness(consent: false)
        noConsent.state.welcomeCompleted = true
        #expect(code(await send(noConsent.state, "start", ["title": "x"])) == .notReady)
        #expect(noConsent.state.welcomeCompleted) // unlike prepareRecording, never reopens the welcome screen
        let status = try result(await send(noConsent.state, "status"))
        #expect(status["ready"] == false)
        #expect(status["not_ready_reason"]?.stringValue?.contains("consent") == true)
        #expect(noModels.recorder.starts == 0 && noConsent.recorder.starts == 0)
    }

    @Test("start records system audio, stores title, event id and attendees, and status reports the actual mode")
    func startAndStatus() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let started = try result(await send(h.state, "start", ["title": "Weekly sync", "event_id": "google-evt-1",
            "attendees": [["name": "Ana Fixture", "email": "Ana@Example.com"], ["name": "No Email"]]]))
        let id = try #require(started["meeting_id"]?.stringValue)
        #expect(started["capture_mode"] == "system_audio")
        #expect(h.state.isRecording)
        #expect(h.recorder.includedMicrophone == false)

        let meeting = try #require(h.store.getMeeting(id: id))
        #expect(meeting.title == "Weekly sync")
        #expect(meeting.calendarEventId == "google-evt-1")
        #expect(meeting.status == "recording")
        #expect(h.store.listMeetingAttendees(meetingId: id).map(\.email) == ["ana@example.com"])

        let status = try result(await send(h.state, "status"))
        #expect(status["recording"] == true)
        #expect(status["meeting_id"] == .string(id))
        #expect(status["capture_mode"] == "system_audio")
        #expect(status["ready"] == true)
        #expect(status["version"]?.stringValue?.contains("(") == true)
        for key in ["duration_s", "processing", "system_audio_permission", "default_output_device", "default_input_device", "not_ready_reason"] {
            #expect(status[key] != nil, "missing \(key)")
        }

        #expect(code(await send(h.state, "start", ["title": "Second"])) == .busy)
        #expect(h.recorder.starts == 1)

        let mark = try result(await send(h.state, "mark", ["label": "Decision"]))
        #expect(mark["label"] == "Decision")
        #expect(h.store.listBookmarks(meetingId: id).map(\.label) == ["Decision"])

        #expect(code(await send(h.state, "stop", ["meeting_id": "other"])) == .wrongMeeting)
        let stopped = try result(await send(h.state, "stop", ["meeting_id": .string(id)]))
        #expect(stopped == ["meeting_id": .string(id), "processing": true])
        #expect(!h.state.isRecording)
        for _ in 0..<200 where h.state.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.store.getMeeting(id: id)?.title == "Weekly sync") // an API title is never auto-renamed
        #expect(code(await send(h.state, "stop", ["meeting_id": .string(id)])) == .notRecording)
        #expect(code(await send(h.state, "mark")) == .notRecording)
    }

    @Test("system_and_microphone includes the microphone track")
    func systemAndMicrophone() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let started = try result(await send(h.state, "start", ["title": "Call", "capture_mode": "system_and_microphone"]))
        #expect(started["capture_mode"] == "system_and_microphone")
        #expect(h.recorder.includedMicrophone == true)
        #expect(h.store.getMeeting(id: started["meeting_id"]?.stringValue ?? "")?.calendarEventId == nil)
        #expect(try result(await send(h.state, "status"))["capture_mode"] == "system_and_microphone")
        _ = await send(h.state, "stop", ["meeting_id": started["meeting_id"]!])
    }

    @Test("Unknown methods and invalid params map to their error codes")
    func errorMapping() async throws {
        let h = try harness()
        #expect(code(await send(h.state, "delete_everything")) == .unknownMethod)
        #expect(code(await send(h.state, "start")) == .badRequest)
        #expect(code(await send(h.state, "start", ["title": "x", "capture_mode": "microphone"])) == .badRequest)
        #expect(code(await send(h.state, "get", ["meeting_id": "missing"])) == .notFound)
        #expect(code(await send(h.state, "assign", ["meeting_id": "missing", "cluster_id": "c", "name": "A"])) == .notFound)
        #expect(code(await send(h.state, "export", ["meeting_id": "missing"])) == .notFound)
        #expect(code(await send(h.state, "stop", ["meeting_id": "m"])) == .notRecording)
    }

    private func reviewedMeeting(_ store: MinutesStore) throws {
        try store.saveMeeting(Meeting(id: "m", title: "Review fixture", status: "needs_review"))
        try store.saveSpeakerClusters([
            SpeakerCluster(id: "c1", meetingId: "m", trackId: "system", label: "Speaker 1", speechSeconds: 12, confidence: 0.3),
            SpeakerCluster(id: "c2", meetingId: "m", trackId: "system", label: "Speaker 2", speechSeconds: 4)
        ])
        try store.saveUtterances([
            Utterance(id: 1, meetingId: "m", clusterId: "c1", speakerName: "c1", start: 0, end: 1.5, text: "Synthetic first"),
            Utterance(id: 2, meetingId: "m", clusterId: "c2", speakerName: "c2", start: 1.5, end: 3, text: "Synthetic second")
        ])
        try store.saveSummary(MeetingSummary(meetingId: "m", title: "Review fixture", overview: "Speaker 1 proposed the plan.", markdown: "Speaker 1 proposed the plan."))
    }

    @Test("get returns the meeting, clusters and readable utterances")
    func getShape() async throws {
        let h = try harness()
        try reviewedMeeting(h.store)
        let got = try result(await send(h.state, "get", ["meeting_id": "m"]))
        #expect(got["meeting"]?["id"] == "m")
        #expect(got["meeting"]?["status"] == "needs_review")
        #expect(got["meeting"]?["started_at"]?.numberValue != nil)
        #expect(got["meeting"]?["ended_at"] == .null)
        #expect(got["meeting"]?["calendar_event_id"] == .null)
        #expect(got["clusters"]?.arrayValue?.first == ["id": "c1", "track_id": "system", "label": "Speaker 1", "speech_seconds": 12,
                                                       "assignment": "suggested", "person_id": nil, "confidence": 0.3])
        #expect(got["utterances"]?.arrayValue?.first == ["id": 1, "cluster_id": "c1", "speaker_name": "Speaker 1", "start": 0, "end": 1.5, "text": "Synthetic first"])
    }

    @Test("assign over the API matches the review screen and rewrites the summary")
    func assignMatchesUI() async throws {
        // API path.
        let api = try harness()
        try reviewedMeeting(api.store)
        let assigned = try result(await send(api.state, "assign", ["meeting_id": "m", "cluster_id": "c1", "name": "Ana Fixture", "email": "ana@example.com"]))
        #expect(assigned["cluster"]?["label"] == "Ana Fixture")
        #expect(assigned["cluster"]?["assignment"] == "user")
        #expect(assigned["learned"] == false)
        #expect(api.store.getSummary(meetingId: "m")?.overview == "Ana Fixture proposed the plan.")

        // UI path: the review screen's onAssign then onReassignUtterances.
        let ui = try harness()
        try reviewedMeeting(ui.store)
        ui.state.selectMeeting(id: "m")
        let person = Person(displayName: "Ana Fixture", emails: ["ana@example.com"])
        try ui.state.assignSpeaker(meetingID: "m", clusterID: "c1", person: person)
        try ui.state.renameSpeakerUtterances(meetingID: "m", clusterID: "c1", name: person.displayName)
        #expect(ui.state.currentClusters.first { $0.id == "c1" }?.label == "Ana Fixture")
        #expect(ui.state.currentUtterances.first?.speakerName == "Ana Fixture")
        #expect(ui.store.getSummary(meetingId: "m")?.overview == "Ana Fixture proposed the plan.")

        func snapshot(_ store: MinutesStore) -> [String] {
            store.listSpeakerClusters(meetingId: "m").map { "\($0.id)|\($0.label)|\($0.assignment)|\($0.confidence)|\($0.personId != nil)" }
                + store.listUtterances(meetingId: "m").map { "\($0.id)|\($0.speakerName)" }
        }
        #expect(snapshot(api.store) == snapshot(ui.store))

        #expect(code(await send(api.state, "assign", ["meeting_id": "m", "cluster_id": "nope", "name": "A"])) == .notFound)
        #expect(code(await send(api.state, "assign", ["meeting_id": "m", "cluster_id": "c2", "name": "A", "learn": true])) == .badRequest)
        #expect(api.store.listSpeakerClusters(meetingId: "m").first { $0.id == "c2" }?.label == "Speaker 2")

        try api.store.saveMeeting(Meeting(id: "busy", title: "Processing", status: "processing"))
        #expect(code(await send(api.state, "assign", ["meeting_id": "busy", "cluster_id": "c1", "name": "A"])) == .busy)
    }

    @Test("export without a connected vault reports exported false")
    func exportWithoutVault() async throws {
        let h = try harness()
        try reviewedMeeting(h.store)
        let exported = try result(await send(h.state, "export", ["meeting_id": "m"]))
        #expect(exported["exported"] == false)
        #expect(exported["path"] == .null)
    }

    @Test("The socket server relays to AppState on the main actor")
    func throughSocket() async throws {
        let h = try harness()
        let path = "/tmp/mca-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlSocketServer(path: path) { [state = h.state] request in await state.handleControlRequest(request) }
        try server.start(); defer { server.stop() }
        let response = try await Task.detached {
            try ControlSocketClient(path: path, timeout: 10).send(ControlRequest(id: 42, method: "status"))
        }.value
        #expect(response.id == 42)
        #expect(try result(response)["recording"] == false)
    }
}
#endif
