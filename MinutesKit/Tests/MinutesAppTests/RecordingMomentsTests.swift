import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesCalendar
@testable import MinutesApp

@MainActor struct RecordingMomentsTests {
    @Test("Moments marked while recording are saved at the recording time, renamable, removable and kept after stop")
    func markDuringRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-moments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting_fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!; buffer.frameLength = 16_000
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        let state = try AppState(store: store, audioDirectory: root, preferences: UserDefaults(suiteName: "minutes-moments-" + UUID().uuidString)!,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { audio },
            processAudio: { id, _, _ in PipelineResult(meetingId: id, audioDuration: 1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: [], speechDuration: 0) },
            summarizeMeeting: { meeting, _, _, _, _ in MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "", markdown: "") })
        #expect(state.markRecordingMoment() == nil)
        state.startQuickMeeting()
        let id = try #require(state.activeRecordingMeetingID)
        state.recordingMeter.update(duration: 42.5, level: 0.2)
        let mark = try #require(state.markRecordingMoment())
        #expect(mark.timestamp == 42.5 && state.recordingBookmarks.map(\.id) == [mark.id])
        state.renameBookmark(mark, to: "Budget decision")
        #expect(state.recordingBookmarks.first?.label == "Budget decision")
        let extra = try #require(state.markRecordingMoment())
        state.deleteBookmark(extra)
        #expect(state.recordingBookmarks.count == 1)
        await state.stopAndProcessMeeting()
        #expect(store.listBookmarks(meetingId: id).map(\.label) == ["Budget decision"])
    }
}

@MainActor struct LibrarySyncAvailabilityTests {
    @Test("Without the iCloud entitlement, sync stays off and never touches CloudKit")
    func unavailableWithoutEntitlement() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let state = try AppState(store: store, audioDirectory: FileManager.default.temporaryDirectory,
                                 preferences: UserDefaults(suiteName: "minutes-sync-" + UUID().uuidString)!)
        #expect(AppState.cloudKitContainerIdentifier == nil && !state.librarySyncAvailable)
        state.iCloudSyncEnabled = true
        #expect(state.librarySync == nil && state.librarySyncStatus == nil)
        #expect(state.librarySyncDescription.contains("isn’t included"))
    }
}

@MainActor struct GoogleCalendarChoiceTests {
    @Test("Choosing calendars by name stores real ids and keeps the main calendar until it is unticked")
    func chooseCalendars() throws {
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: FileManager.default.temporaryDirectory,
                                 preferences: UserDefaults(suiteName: "minutes-gcal-" + UUID().uuidString)!)
        let json = #"[{"id":"me@example.test","summary":"Me","primary":true},{"id":"team@group.calendar.google.com","summary":"Team"}]"#
        state.googleCalendarChoices = try JSONDecoder().decode([GoogleCalendarDescriptor].self, from: Data(json.utf8))
        #expect(state.isGoogleCalendarSelected(state.googleCalendarChoices[0]) && !state.isGoogleCalendarSelected(state.googleCalendarChoices[1]))
        state.setGoogleCalendar(state.googleCalendarChoices[1], included: true)
        #expect(state.selectedGoogleCalendarIDs == ["me@example.test", "team@group.calendar.google.com"])
        state.setGoogleCalendar(state.googleCalendarChoices[0], included: false)
        #expect(state.selectedGoogleCalendarIDs == ["team@group.calendar.google.com"])
        state.setGoogleCalendar(state.googleCalendarChoices[1], included: false)
        #expect(state.selectedGoogleCalendarIDs == ["primary"])
    }
}
