import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSummarize
@testable import MinutesApp

@MainActor struct AutomaticCompletionTests {
    private func fixture(empty: Bool = false, summaryFails: Bool = false, autoFolder: Bool = false) throws -> (AppState, MinutesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-completion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
        buffer.floatChannelData![0].update(repeating: 0.01, count: 1600)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        if autoFolder { _ = try store.createFolder(name: "Observatory", description: "Telescope calibration and lens inspection") }
        let state = try AppState(store: store, audioDirectory: root, preferences: UserDefaults(suiteName: "minutes-completion-" + UUID().uuidString)!, recordingModelReadiness: { (true, "Ready") },
            captureStart: { _ in }, captureStop: { audio },
            processAudio: { id, _, _ in
                let utterances = empty ? [] : [Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Unknown", start: 0, end: 0.1, text: "Telescope calibration needs a lens inspection. Telescope calibration begins Tuesday.")]
                return PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: utterances, speechDuration: empty ? 0 : 0.1)
            }, classifyMeetingFolder: { _, candidates in
                FolderClassificationResult(folderID: candidates.first?.folder.id, status: .matched, reason: "Strong fixture match", similarity: 0.95, margin: 0.4)
            }, summarizeMeeting: { meeting, utterances, _, _, _ in
                if summaryFails { throw CocoaError(.featureUnsupported) }
                return MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: utterances.map(\.text).joined(separator: " "), markdown: "Automatically prepared notes")
            })
        return (state, store, root)
    }
    @Test func successfulStopCreatesNotesAndUsefulTitle() async throws {
        let (state, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        let saved = try #require(store.getMeeting(id: id))
        #expect(!saved.title.hasPrefix("Meeting ("))
        #expect(saved.title.localizedCaseInsensitiveContains("telescope") || saved.title.localizedCaseInsensitiveContains("calibration"))
        #expect(store.getSummary(meetingId: id)?.markdown == "Automatically prepared notes")
        #expect(!state.isRecording && !state.isProcessing && !state.isSummarizing)
    }
    @Test func manualTitleAndExistingSummaryArePreserved() async throws {
        let (state, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        var meeting = try #require(store.getMeeting(id: id)); meeting.title = "My chosen name"; try store.saveMeeting(meeting)
        try store.saveSummary(MeetingSummary(meetingId: id, title: "Manual", overview: "Manual", markdown: "Keep my summary"))
        await state.stopAndProcessMeeting()
        #expect(store.getMeeting(id: id)?.title == "My chosen name")
        #expect(store.getSummary(meetingId: id)?.markdown == "Keep my summary")
    }
    @Test func emptySpeechDoesNotInventNotesOrTitle() async throws {
        let (state, store, root) = try fixture(empty: true); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        #expect(store.getSummary(meetingId: id) == nil)
        #expect(state.statusMessage.localizedCaseInsensitiveContains("no speech"))
        #expect(store.getMeeting(id: id)?.audioPath != nil)
    }
    @Test func summaryFailurePreservesTranscriptWithoutSubstitutingExtractiveNotes() async throws {
        let (state, store, root) = try fixture(summaryFails: true); defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting(); let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        #expect(store.getSummary(meetingId: id) == nil)
        #expect(!store.listUtterances(meetingId: id).isEmpty)
        #expect(state.statusMessage.contains("AI summary pending"))
        #expect(store.getMeeting(id: id)?.status == "needs_review")
        #expect(!state.isSummarizing)
    }
    @Test func completedRecordingIsAutomaticallyFiledAfterNotes() async throws {
        let (state, store, root) = try fixture(autoFolder: true)
        defer { try? FileManager.default.removeItem(at: root) }
        state.startQuickMeeting()
        let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        #expect(store.getSummary(meetingId: id) != nil)
        let membership = try #require(try store.folderMembership(meetingID: id))
        #expect(membership.folderID == state.folders.first?.id)
        #expect(membership.source == .automatic)
    }
    @Test func recordingInAnExplicitFolderKeepsThatManualChoice() async throws {
        let (state, store, root) = try fixture(autoFolder: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try #require(state.folders.first)
        state.selectLibrary(.folder(folder.id))
        state.startQuickMeeting()
        let id = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        let membership = try #require(try store.folderMembership(meetingID: id))
        #expect(membership.folderID == folder.id)
        #expect(membership.source == .manual)
    }
}

extension AutomaticCompletionTests {
    @Test func regeneratingSummaryRenamesTimestampNotesAndAvoidsDuplicateTitles() async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let prefs = UserDefaults(suiteName: "title-retry-" + UUID().uuidString)!
        let state = try AppState(store: store, preferences: prefs, summarizeMeeting: { m, _, _, _, _ in
            MeetingSummary(meetingId: m.id, title: m.title, overview: "Telescope calibration", markdown: "# \(m.title)\n\nCalibration decisions")
        })
        var titles: [String] = []
        for id in ["one", "two"] {
            let meeting = Meeting(id: id, title: "Meeting (10/17/26, 1:00 PM)", startedAt: Date(), status: "needs_review")
            try store.saveMeeting(meeting)
            try store.saveUtterances([Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Speaker", start: 0, end: 5, text: "Telescope calibration requires lens inspection. Telescope calibration starts Tuesday.")])
            state.selectMeeting(id: id)
            await state.generateCurrentSummary()
            let renamed = try #require(store.getMeeting(id: id))
            #expect(!renamed.title.hasPrefix("Meeting ("))
            #expect(renamed.title.localizedCaseInsensitiveContains("telescope"))
            #expect(state.currentMeeting?.title == renamed.title)
            #expect(store.getSummary(meetingId: id)?.title == renamed.title)
            #expect(store.getSummary(meetingId: id)?.markdown.hasPrefix("# \(renamed.title)\n") == true)
            titles.append(renamed.title)
        }
        #expect(titles[0] != titles[1])
    }

    @Test(arguments: ["My telescope plans", "Meeting (Product strategy)"])
    func summaryRetryPreservesCustomTitle(title: String) async throws {
        let (state, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(id: "manual-title", title: title, startedAt: Date(), status: "needs_review")
        try store.saveMeeting(meeting)
        try store.saveUtterances([Utterance(id: 1, meetingId: meeting.id, clusterId: "", speakerName: "Speaker", start: 0, end: 5, text: "Telescope calibration needs lens inspection.")])
        state.selectMeeting(id: meeting.id)
        await state.generateCurrentSummary()
        #expect(store.getMeeting(id: meeting.id)?.title == meeting.title)
    }
}
