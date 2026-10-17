import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSummarize
@testable import MinutesApp

private actor SuspendedPipeline {
    private var id = ""
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<PipelineResult, any Error>?
    func run(id: String) async throws -> PipelineResult {
        self.id = id; entered = true; waiting?.resume(); waiting = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func wait() async { if entered { return }; await withCheckedContinuation { waiting = $0 } }
    func finish(fail: Bool) {
        if fail { pending?.resume(throwing: ASRError.transcriptionFailed("Injected processing failure")) }
        else { pending?.resume(returning: PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: [], speechDuration: 0)) }
        pending = nil
    }
}
private actor SuspendedSummary {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<MeetingSummary, any Error>?
    func run() async throws -> MeetingSummary {
        entered = true; waiting?.resume(); waiting = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func wait() async { if entered { return }; await withCheckedContinuation { waiting = $0 } }
    func finish() { pending?.resume(returning: MeetingSummary(meetingId: "fixture", title: "Generated", overview: "Generated", markdown: "Generated")); pending = nil }
}
@MainActor struct ConcurrentEditsTests {
    @Test(arguments: ["retry-success", "retry-failure", "import-success", "import-failure", "stop-success", "stop-failure"])
    func processingPreservesEditsMadeWhileSuspended(_ variant: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-edits-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        let audio = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.01 }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let gate = SuspendedPipeline()
        let state = try AppState(store: store, audioDirectory: root.appendingPathComponent("audio"), recordingModelReadiness: { (true, "Fixture models ready") }, captureStart: { _ in }, captureStop: { audio }, processAudio: { id, _, _ in try await gate.run(id: id) })
        if variant.hasPrefix("retry") {
            try store.saveMeeting(Meeting(id: "fixture", title: "Original", audioPath: audio.path))
            state.selectMeeting(id: "fixture")
        }
        if variant.hasPrefix("stop") { state.startQuickMeeting() }
        let task = Task {
            if variant.hasPrefix("retry") { await state.processCurrentMeeting() }
            else if variant.hasPrefix("stop") { await state.stopAndProcessMeeting() }
            else { _ = try await state.importMedia(from: audio) }
        }
        await gate.wait()
        var edited = try #require(store.listMeetings().first)
        edited.title = "Manual title"; edited.userNotes = "Manual notes during processing"; edited.conferenceURL = "https://meeting.example/edited"
        try store.saveMeeting(edited)
        try store.saveSummary(MeetingSummary(meetingId: edited.id, title: "Manual summary", overview: "Manual summary", markdown: "Keep manual summary"))
        await gate.finish(fail: variant.hasSuffix("failure"))
        try await task.value
        let saved = try #require(store.getMeeting(id: edited.id))
        #expect(saved.title == "Manual title")
        #expect(saved.userNotes == "Manual notes during processing")
        #expect(saved.conferenceURL == "https://meeting.example/edited")
        #expect(saved.status == (variant.hasSuffix("failure") ? "recorded" : "needs_review"))
        #expect(store.getSummary(meetingId: edited.id)?.markdown == "Keep manual summary")
    }
    @Test func generatedSummaryCannotOverwriteConcurrentManualSummary() async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "fixture", title: "Fixture"))
        try store.saveSummary(MeetingSummary(meetingId: "fixture", title: "Before", overview: "Before", markdown: "Before"))
        let gate = SuspendedSummary()
        let state = try AppState(store: store, summarizeMeeting: { _, _, _, _, _ in try await gate.run() })
        state.selectMeeting(id: "fixture")
        let task = Task { await state.generateCurrentSummary() }
        await gate.wait()
        try store.saveSummary(MeetingSummary(meetingId: "fixture", title: "Manual", overview: "Manual", markdown: "Saved while generating"))
        await gate.finish(); await task.value
        #expect(store.getSummary(meetingId: "fixture")?.markdown == "Saved while generating")
        #expect(state.statusMessage.contains("preserved"))
        #expect(!state.isSummarizing)
    }
}
