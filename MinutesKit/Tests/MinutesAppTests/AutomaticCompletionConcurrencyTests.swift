import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSummarize
@testable import MinutesApp

private actor AutomaticSummaryGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<MeetingSummary, Never>?
    private var meetingID = ""
    func run(_ meeting: Meeting) async -> MeetingSummary {
        meetingID = meeting.id; entered = true; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        pending?.resume(returning: MeetingSummary(meetingId: meetingID, title: "Generated", overview: "Generated", markdown: "Automatic captured notes"))
        pending = nil
    }
}

@MainActor struct AutomaticCompletionConcurrencyTests {
    @Test(arguments: ["selection", "summary-edit", "title-edit"])
    func automaticNotesRespectCapturedIdentityAndConcurrentEdits(_ variant: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-auto-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)); pcm.frameLength = 1600
        pcm.floatChannelData![0].update(repeating: 0.01, count: 1600)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        let gate = AutomaticSummaryGate()
        let state = try AppState(store: store, audioDirectory: root,
            recordingModelReadiness: { (true, "Fixture ready") }, captureStart: { _ in }, captureStop: { audio },
            processAudio: { id, _, _ in
                PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [],
                    utterances: [Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Unknown", start: 0, end: 0.1,
                                          text: "Telescope calibration requires inspection. Telescope calibration begins Tuesday.")], speechDuration: 0.1)
            }, summarizeMeeting: { meeting, _, _, _, _ in await gate.run(meeting) })
        state.startQuickMeeting()
        let capturedID = try #require(state.activeRecordingMeetingID)
        let other = Meeting(id: "other", title: "Other meeting")
        try store.saveMeeting(other)
        try store.saveSummary(MeetingSummary(meetingId: other.id, title: other.title, overview: "Other", markdown: "Other notes"))
        let task = Task { await state.stopAndProcessMeeting() }
        await gate.wait()
        #expect(!state.isFinalizingRecording)
        #expect(state.isProcessing && state.isSummarizing)
        if variant == "summary-edit" {
            try store.saveSummary(MeetingSummary(meetingId: capturedID, title: "Manual", overview: "Manual", markdown: "Keep manual notes"))
        } else if variant == "title-edit" {
            var edited = try #require(store.getMeeting(id: capturedID)); edited.title = "My newer title"; try store.saveMeeting(edited)
        }
        state.selectMeeting(id: other.id)
        await gate.finish(); await task.value
        #expect(state.selectedMeetingId == other.id)
        #expect(store.getSummary(meetingId: other.id)?.markdown == "Other notes")
        if variant == "summary-edit" {
            #expect(store.getSummary(meetingId: capturedID)?.markdown == "Keep manual notes")
        } else if variant == "title-edit" {
            #expect(store.getMeeting(id: capturedID)?.title == "My newer title")
            #expect(store.getSummary(meetingId: capturedID) == nil)
        } else {
            #expect(store.getSummary(meetingId: capturedID)?.markdown == "Automatic captured notes")
        }
        #expect(!state.isProcessing && !state.isSummarizing && !state.isFinalizingRecording)
    }
}

extension AutomaticCompletionConcurrencyTests {
    @Test(arguments: [false, true], ["user", "unknown"])
    func retryKeepsHumanIdentityOnlyForIdenticalAcousticEvidence(changedEvidence: Bool, assignment: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-identity-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)); pcm.frameLength = 160
        pcm.floatChannelData![0].update(repeating: 0.01, count: 160)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        let store = try MinutesStore(dbPath: ":memory:")
        let person = Person(id: "confirmed-person", displayName: "Confirmed person"); try store.savePerson(person)
        try store.saveMeeting(Meeting(id: "retry-meeting", title: "Manual title", audioPath: audio.path))
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        let original = SpeakerCluster(id: "cluster", meetingId: "retry-meeting", trackId: "track", label: assignment == "user" ? person.displayName : "Unknown Speaker",
            centroid: vector, speechSeconds: 12, personId: assignment == "user" ? person.id : nil, assignment: assignment, confidence: 1,
            embeddingModel: SpeakerEmbeddingModel.trainedID)
        try store.saveSpeakerClusters([original])
        let fresh = SpeakerCluster(id: original.id, meetingId: original.meetingId, trackId: original.trackId, label: "Speaker 1",
            centroid: changedEvidence ? [0, 1] + Array(repeating: 0, count: 254) : vector,
            speechSeconds: original.speechSeconds, assignment: "unassigned", embeddingModel: original.embeddingModel)
        let state = try AppState(store: store, processAudio: { id, _, _ in
            PipelineResult(meetingId: id, audioDuration: 12, sampleRate: 16000, words: [], segments: [], clusters: [fresh], utterances: [], speechDuration: 12)
        })
        state.selectMeeting(id: "retry-meeting")
        await state.processCurrentMeeting()
        let saved = try #require(store.listSpeakerClusters(meetingId: "retry-meeting").first)
        #expect(saved.personId == (changedEvidence ? nil : original.personId))
        #expect(saved.assignment == (changedEvidence ? "unassigned" : assignment))
        #expect(saved.label == (changedEvidence ? "Speaker 1" : original.label))
    }
}
