#if os(macOS)
import Foundation
import Testing
import MinutesCore
import MinutesCalendar
@testable import MinutesApp

@MainActor
struct CaptureModeDefaultTests {
    private func preferences() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "minutes-capture-mode-\(UUID())"))
    }

    @Test("The Mac app's default captures call audio and microphone; a saved choice wins on relaunch")
    func defaultAndPersistence() throws {
        let prefs = try preferences()
        let first = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: prefs, defaultCaptureMode: .systemAndMicrophone)
        #expect(first.captureMode == .systemAndMicrophone)
        first.captureMode = .microphone
        let relaunched = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: prefs, defaultCaptureMode: .systemAndMicrophone)
        #expect(relaunched.captureMode == .microphone)
    }

    @Test("An unknown saved value falls back to the default instead of mic-only")
    func unknownSavedValue() throws {
        let prefs = try preferences()
        prefs.set("Mac call audio + microphone", forKey: "captureMode")
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: prefs, defaultCaptureMode: .systemAndMicrophone)
        #expect(state.captureMode == .systemAndMicrophone)
    }

    @Test("Without call-audio permission, a call-audio start still records the microphone and says why")
    func missingCallAudioPermissionFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var started: URL?
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: root, preferences: preferences(),
            defaultCaptureMode: .systemAndMicrophone, recordingModelReadiness: { (true, "Fixture models ready") },
            captureStart: { started = $0 }, captureStop: { nil })
        state.systemCapturePreflight = { false }
        state.startQuickMeeting()
        #expect(state.isRecording)
        #expect(started != nil)
        #expect(state.statusMessage.contains("only your microphone is recording"))
    }

    @Test("Pressing Record during the only invited meeting keeps its invitees for speaker review")
    func recordDuringMeetingBindsInvitees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-bind-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MinutesStore(dbPath: ":memory:")
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences(),
            defaultCaptureMode: .microphone, recordingModelReadiness: { (true, "Fixture models ready") },
            captureStart: { _ in }, captureStop: { nil })
        state.upcomingEvents = [CalendarMeetingEvent(eventIdentifier: "tactical", calendarIdentifier: "cal", title: "Product Tactical",
            start: Date().addingTimeInterval(-180), end: Date().addingTimeInterval(1_800),
            attendees: CalendarParticipantMapper.map([CalendarParticipant(name: "Ada", url: "mailto:ada@example.com", isCurrentUser: false, responseStatus: "accepted")]))]
        state.startQuickMeeting()
        let id = try #require(state.activeRecordingMeetingID)
        #expect(store.getMeeting(id: id)?.title == "Product Tactical")
        #expect(store.listPeopleForMeeting(meetingId: id).map(\.displayName) == ["Ada"])
    }
}
#endif
