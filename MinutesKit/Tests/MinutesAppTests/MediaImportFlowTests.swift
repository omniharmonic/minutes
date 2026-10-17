import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor
struct MediaImportFlowTests {
    private func fixture() throws -> (URL, URL, MinutesStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-app-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MinutesStore(dbPath: root.appendingPathComponent("minutes.sqlite").path)
        let source = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.01 }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        return (root, source, store)
    }

    @Test("Unavailable processing preserves the imported managed recording for retry")
    func processingFailurePreservesImport() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try AppState(store: store, audioDirectory: root.appendingPathComponent("audio"), processAudio: { _, _, _ in
            throw ASRError.recognizerUnavailable("Isolated missing-model fixture")
        })
        let meeting = try await state.importMedia(from: source)
        #expect(meeting.status == "recorded")
        #expect(!state.isProcessing)
        #expect(state.statusMessage.contains("processing pending"))
        let audioPath = try #require(store.getMeeting(id: meeting.id)?.audioPath)
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        #expect(store.listUtterances(meetingId: meeting.id).isEmpty)
        await state.processCurrentMeeting()
        #expect(store.getMeeting(id: meeting.id)?.status == "recorded")
        #expect(FileManager.default.fileExists(atPath: audioPath))
    }

    @Test("App import invokes the shared pipeline and commits its result for review")
    func processingSuccessPersistsResult() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try AppState(store: store, audioDirectory: root.appendingPathComponent("audio"), processAudio: { id, _, _ in
            let utterance = Utterance(id: 1, meetingId: id, clusterId: "fixture", speakerName: "Unknown", start: 0, end: 0.1, text: "Injected test result")
            return PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: [utterance], speechDuration: 0.1)
        }, summarizeMeeting: { meeting, _, _, _, _ in
            MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "Synthetic", markdown: "Imported summary")
        })
        let meeting = try await state.importMedia(from: source)
        #expect(store.getSummary(meetingId: meeting.id)?.markdown == "Imported summary")
        #expect(meeting.status == "needs_review")
        #expect(store.getMeeting(id: meeting.id)?.status == "needs_review")
        #expect(store.listUtterances(meetingId: meeting.id).first?.text == "Injected test result")
    }
}
