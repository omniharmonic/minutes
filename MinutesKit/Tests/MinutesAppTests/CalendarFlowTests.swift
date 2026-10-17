import Foundation
import Testing
import MinutesCore
import MinutesCalendar
import EventKit
@testable import MinutesApp

@MainActor
private final class FakeCalendarProvider: CalendarProviding {
    var hasAccess = false
    var fetchCount = 0
    var requestCount = 0
    let fixture: CalendarMeetingEvent
    init(fixture: CalendarMeetingEvent) { self.fixture = fixture }
    func requestAccess() async throws { requestCount += 1; hasAccess = true }
    func events(in interval: DateInterval) throws -> [CalendarMeetingEvent] {
        fetchCount += 1
        return CalendarMeetingEvent.scoped([fixture], interval: interval)
    }
}

@MainActor
@Suite(.serialized)
struct CalendarFlowTests {
    @Test("Explicit calendar connect scopes invitees and Record binds the selected occurrence")
    func connectAndRecordEvent() async throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-calendar-flow-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try MinutesStore(dbPath: dbURL.path)
        let event = CalendarMeetingEvent(eventIdentifier: "event", calendarIdentifier: "work", title: "Calendar planning",
            start: Date().addingTimeInterval(30), end: Date().addingTimeInterval(1800),
            attendees: CalendarParticipantMapper.map([CalendarParticipant(name: "Ana", url: "mailto:ana@example.com", isCurrentUser: false)]))
        let provider = FakeCalendarProvider(fixture: event)
        let state = try AppState(store: store, calendarProvider: provider,
            audioDirectory: FileManager.default.temporaryDirectory, recordingModelReadiness: { (true, "Fixture models ready") }, captureStart: { _ in }, captureStop: { nil })
        #expect(provider.fetchCount == 0)
        await state.connectCalendar()
        #expect(provider.fetchCount == 1)
        #expect(state.upcomingEvents.map(\.id) == [event.id])
        #expect(state.calendarPrompt?.id == event.id)
        state.startQuickMeeting(event: event)
        let meeting = try #require(store.listMeetings().first)
        #expect(meeting.calendarEventId == event.id)
        #expect(meeting.title == event.title)
        #expect(state.isRecording)
        #expect(store.listPeopleForMeeting(meetingId: meeting.id).map(\.displayName) == ["Ana"])
        #expect(store.listVoiceprints().isEmpty)
        await state.stopAndProcessMeeting()
    }
}


private final class NoSavedCalendarCredentials: OAuthCredentialStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func readWithoutInteraction(service: String, account: String) throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

extension CalendarFlowTests {
    @Test("Saved authorized Apple Calendar silently restores once and keeps one refresh observer")
    func savedAppleCalendarRestoresWithoutRequestingAccess() async throws {
        let suite = "apple-calendar-restore-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("apple", forKey: "calendarProvider")
        let event = CalendarMeetingEvent(eventIdentifier: "saved", calendarIdentifier: "work", title: "Fictional planning",
            start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(1800))
        let provider = FakeCalendarProvider(fixture: event)
        provider.hasAccess = true
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), calendarProvider: provider, preferences: prefs)
        await state.restoreCalendarConnections()
        await state.restoreCalendarConnections()
        #expect(state.calendarConnected)
        #expect(state.calendarSource == .apple)
        #expect(state.upcomingEvents.map(\.id) == [event.id])
        #expect(provider.requestCount == 0)
        #expect(provider.fetchCount == 1)
        let beforeChange = provider.fetchCount
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        for _ in 0..<30 {
            if provider.fetchCount > beforeChange { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(provider.fetchCount == beforeChange + 1)
        #expect(prefs.string(forKey: "calendarProvider") == "apple")
    }

    @Test("Saved Apple Calendar without access never prompts at startup")
    func savedAppleCalendarNeedsExplicitConnectionWhenAccessIsMissing() async throws {
        let suite = "apple-calendar-no-access-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("apple", forKey: "calendarProvider")
        let event = CalendarMeetingEvent(eventIdentifier: "saved", calendarIdentifier: "work", title: "Fictional planning", start: Date(), end: Date().addingTimeInterval(600))
        let provider = FakeCalendarProvider(fixture: event)
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), calendarProvider: provider, preferences: prefs)
        await state.restoreCalendarConnections()
        #expect(!state.calendarConnected)
        #expect(provider.requestCount == 0)
        #expect(provider.fetchCount == 0)
        #expect(state.calendarMessage.contains("Connect Apple Calendar"))
    }

    @Test("Silent Apple restore respects Google, disconnected and unselected providers")
    func otherProviderChoicesDoNotReadAppleCalendar() async throws {
        for choice in ["none", "google", "unset"] {
            let suite = "apple-calendar-choice-" + UUID().uuidString
            let prefs = try #require(UserDefaults(suiteName: suite))
            defer { prefs.removePersistentDomain(forName: suite) }
            if choice != "unset" { prefs.set(choice, forKey: "calendarProvider") }
            let event = CalendarMeetingEvent(eventIdentifier: "saved", calendarIdentifier: "work", title: "Fictional planning", start: Date(), end: Date().addingTimeInterval(600))
            let provider = FakeCalendarProvider(fixture: event)
            provider.hasAccess = true
            let google = GoogleCalendarConnection(configuration: .init(desktopClientID: "fixture.apps.googleusercontent.com"), credentialStore: NoSavedCalendarCredentials())
            let state = try AppState(store: MinutesStore(dbPath: ":memory:"), calendarProvider: provider, preferences: prefs)
            await state.restoreCalendarConnections(connection: google)
            #expect(!state.calendarConnected)
            #expect(provider.requestCount == 0)
            #expect(provider.fetchCount == 0)
            #expect(prefs.string(forKey: "calendarProvider") == (choice == "unset" ? nil : choice))
        }
    }
}
