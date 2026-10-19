import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor struct AudioStorageFlowTests {
    private func fixture(processingFails: Bool = false) throws -> (AppState, MinutesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-storage-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("meeting_fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!; buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = Float(0.1 * sin(Double(i) * 0.05)) }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        let state = try AppState(store: store, audioDirectory: root, preferences: UserDefaults(suiteName: "minutes-storage-" + UUID().uuidString)!,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { audio },
            processAudio: { id, _, _ in
                if processingFails { throw CocoaError(.featureUnsupported) }
                return PipelineResult(meetingId: id, audioDuration: 2, sampleRate: 16000, words: [], segments: [], clusters: [],
                    utterances: [Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Unknown", start: 0, end: 2, text: "The lens inspection starts Tuesday.")],
                    speechDuration: 2)
            }, summarizeMeeting: { meeting, _, _, _, _ in
                MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "Inspection Tuesday", markdown: "Notes")
            })
        return (state, store, root)
    }

    private func waitForCompactAudio(_ store: MinutesStore, _ id: String) async throws {
        for _ in 0..<100 where store.getMeeting(id: id)?.audioPath?.hasSuffix(".m4a") != true { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test("A transcribed recording compresses automatically once processing finishes")
    func automaticCompactionAfterProcessing() async throws {
        let (state, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        try await waitForCompactAudio(store, id)
        let path = try #require(store.getMeeting(id: id)?.audioPath)
        #expect(path.hasSuffix("meeting_fixture.m4a"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting_fixture.wav").path))
        let entries = await state.audioStorageEntries()
        #expect(entries.map(\.id) == [id] && entries[0].isCompact && entries[0].hasTranscript)
    }

    @Test("A recording whose transcription failed is compressed too, so a retry reads the compact copy")
    func failedProcessingStillCompacts() async throws {
        let (state, store, root) = try fixture(processingFails: true); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        try await waitForCompactAudio(store, id)
        #expect(store.getMeeting(id: id)?.status == "recorded")
        #expect(store.getMeeting(id: id)?.audioPath?.hasSuffix(".m4a") == true)
    }

    @Test("Uncompressed recordings saved by earlier versions are compressed after launch")
    func existingLibraryCompactsOnLaunch() async throws {
        let (_, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("meeting_legacy.wav")
        try FileManager.default.copyItem(at: root.appendingPathComponent("meeting_fixture.wav"), to: legacy)
        try store.saveMeeting(Meeting(id: "legacy", title: "Earlier call", status: "summarized", audioPath: legacy.path))
        try store.saveMeeting(Meeting(id: "crashed", title: "Interrupted call", status: "interrupted", audioPath: root.appendingPathComponent("meeting_fixture.wav").path))
        let relaunched = try AppState(store: store, audioDirectory: root, preferences: UserDefaults(suiteName: "minutes-storage-" + UUID().uuidString)!)
        relaunched.loadInitialData()
        try await waitForCompactAudio(store, "legacy")
        #expect(store.getMeeting(id: "legacy")?.audioPath?.hasSuffix("meeting_legacy.m4a") == true)
        #expect(store.getMeeting(id: "crashed")?.audioPath?.hasSuffix(".wav") == true)
    }

    @Test("Deleting audio keeps the transcript and explains why Regenerate is unavailable")
    func deleteAudioKeepsTranscript() async throws {
        let (state, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        try await waitForCompactAudio(store, id)
        #expect(state.deleteAudio(meetingIDs: [id]) > 0)
        #expect(store.getMeeting(id: id)?.audioPath == nil)
        #expect(store.listUtterances(meetingId: id).count == 1)
        #expect(await state.audioStorageEntries().isEmpty)
        state.selectMeeting(id: id)
        await state.processCurrentMeeting()
        #expect(state.statusMessage.contains("audio was deleted"))
    }
}
