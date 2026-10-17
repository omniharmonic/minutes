import Foundation
import Testing
import MinutesCore
@testable import MinutesCalendar

struct EventCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ id: String, offset: Double = 0, allDay: Bool = false, cancelled: Bool = false) -> CalendarMeetingEvent {
        CalendarMeetingEvent(eventIdentifier: id, calendarIdentifier: "work", title: id,
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 1800),
            isAllDay: allDay, isCancelled: cancelled)
    }

    @Test("Event query uses half-open overlap, sorts starts and rejects all-day/cancelled meetings")
    func temporalScope() {
        let events = [event("later", offset: 600), event("ongoing", offset: -300),
            event("ended", offset: -1800), event("next-window", offset: 3600),
            event("all-day", allDay: true), event("cancelled", cancelled: true)]
        let result = CalendarMeetingEvent.scoped(events, interval: DateInterval(start: now, duration: 3600))
        #expect(result.map(\.title) == ["ongoing", "later"])
    }

    @Test("Participant mapping preserves email identity and organizer/self context")
    func participantMapping() {
        let attendee = CalendarParticipant(name: nil, url: "mailto:ana.lopez+work@example.com", isCurrentUser: true)
        let organizer = CalendarParticipant(name: "Ana", url: "mailto:ANA.LOPEZ+work@example.com", isCurrentUser: true)
        let people = CalendarParticipantMapper.map([attendee], organizer: organizer)
        #expect(people.count == 1)
        #expect(people[0].email == "ana.lopez+work@example.com")
        #expect(people[0].isCurrentUser)
        #expect(people[0].isOrganizer)
        #expect(!people[0].displayName.isEmpty)
    }

    @Test("Recurring occurrences retain distinct prompt and binding identities")
    func occurrenceIdentity() {
        #expect(event("recurring").id != event("recurring", offset: 86400).id)
    }

    @Test("Prompts require an active imminent event and honor suppression")
    func promptScope() {
        let imminent = event("imminent", offset: 60)
        let candidates = [event("ended", offset: -3600), event("future", offset: 3600), event("all-day", allDay: true), imminent]
        #expect(CalendarMeetingEvent.nextPrompt(in: candidates, now: now, suppressedIDs: [])?.id == imminent.id)
        #expect(CalendarMeetingEvent.nextPrompt(in: candidates, now: now, suppressedIDs: [imminent.id]) == nil)
    }

    @Test("Binding persists scoped calendar people without enrolling voiceprints")
    func bindingPersistsMeetingContext() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-calendar-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MinutesStore(dbPath: url.path)
        let meeting = Meeting(id: "recording", title: "Quick meeting", startedAt: now, status: "starting")
        try store.saveMeeting(meeting)
        try store.saveMeeting(Meeting(id: "other", title: "Other"))
        let attendees = CalendarParticipantMapper.map([CalendarParticipant(name: "Ana", url: "mailto:ana@example.com", isCurrentUser: false)])
        let event = CalendarMeetingEvent(eventIdentifier: "event", calendarIdentifier: "work", title: "Planning",
            start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200), attendees: attendees,
            conferenceURL: "https://meet.google.com/abc-defg-hij")
        let bound = try CalendarMeetingBinder.bind(meetingId: meeting.id, event: event, store: store)
        #expect(bound.calendarEventId == event.id)
        #expect(bound.title == "Planning")
        #expect(store.getMeeting(id: meeting.id)?.calendarEventId == event.id)
        #expect(store.getMeeting(id: meeting.id)?.conferenceURL == event.conferenceURL)
        #expect(bound.startedAt == now)
        #expect(bound.conferenceURL == event.conferenceURL)
        #expect(store.listPeopleForMeeting(meetingId: meeting.id).map(\.displayName) == ["Ana"])
        #expect(store.listPeopleForMeeting(meetingId: "other").isEmpty)
        #expect(store.listVoiceprints().isEmpty)
    }

    @Test("Rebinding replaces old invitees rather than mixing two calendar events")
    func rebindingReplacesAttendees() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-calendar-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MinutesStore(dbPath: url.path)
        try store.saveMeeting(Meeting(id: "m", title: "Meeting"))
        for name in ["Ana", "Raj"] {
            let event = CalendarMeetingEvent(eventIdentifier: name, calendarIdentifier: "work", title: name,
                start: now, end: now.addingTimeInterval(1800),
                attendees: CalendarParticipantMapper.map([CalendarParticipant(name: name, url: "mailto:\(name.lowercased())@example.com", isCurrentUser: false)]))
            _ = try CalendarMeetingBinder.bind(meetingId: "m", event: event, store: store)
        }
        #expect(store.listPeopleForMeeting(meetingId: "m").map(\.displayName) == ["Raj"])
    }
}

extension EventCalendarTests {
    @Test("Duplicate invitee and organizer merge self context and retain a known RSVP")
    func duplicateParticipantContext() throws {
        let participants = CalendarParticipantMapper.map([
            CalendarParticipant(name: nil, url: "mailto:casey@example.test", isCurrentUser: false),
            CalendarParticipant(name: "Casey Fixture", url: "mailto:CASEY@example.test", isCurrentUser: true, responseStatus: "tentative")
        ], organizer: CalendarParticipant(name: "Casey Fixture", url: "mailto:casey%40example.test", isCurrentUser: true))
        let participant = try #require(participants.first)
        #expect(participants.count == 1)
        #expect(participant.isCurrentUser)
        #expect(participant.isOrganizer)
        #expect(participant.displayName == "Casey Fixture")
        #expect(participant.responseStatus == "tentative")
    }

    @Test("Calendar binding retains RSVP through a database reopen without asserting attendance")
    func rsvpSurvivesBindingAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-rsvp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite").path
        do {
            let store = try MinutesStore(dbPath: path)
            try store.saveMeeting(Meeting(id: "m", title: "Fixture meeting"))
            let attendees = CalendarParticipantMapper.map([
                CalendarParticipant(name: "Casey Fixture", url: "mailto:casey@example.test", isCurrentUser: false, responseStatus: "tentative"),
                CalendarParticipant(name: "Absent Fixture", url: "mailto:absent@example.test", isCurrentUser: false, responseStatus: "declined")
            ])
            _ = try CalendarMeetingBinder.bind(meetingId: "m", event: CalendarMeetingEvent(eventIdentifier: "event", calendarIdentifier: "work", title: "Fixture",
                start: now, end: now.addingTimeInterval(1800), attendees: attendees), store: store)
        }
        let reopened = try MinutesStore(dbPath: path)
        let invitees = reopened.listMeetingAttendees(meetingId: "m")
        #expect(invitees.count == 1, "Declined invitations must not become speaker candidates")
        let data = try JSONEncoder().encode(try #require(invitees.first))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["responseStatus"] as? String == "tentative")
        #expect(reopened.listSpeakerClusters(meetingId: "m").isEmpty)
        #expect(reopened.listVoiceprints().isEmpty)
    }

    @Test("Repeated event occurrences retain exact-email people after reload without merging same-name invitees or learning voices")
    func repeatedCallsKeepStableEmailIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-repeated-calendar-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite").path
        let existing = Person(id: "confirmed-fixture-person", displayName: "Chosen fixture name", emails: ["amber@example.test"])
        func occurrence(offset: Double, email: String) -> CalendarMeetingEvent {
            CalendarMeetingEvent(eventIdentifier: "recurring-fixture", calendarIdentifier: "work", title: "Fixture call",
                start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 1800),
                attendees: CalendarParticipantMapper.map([CalendarParticipant(name: "Calendar display", url: email, isCurrentUser: false),
                    CalendarParticipant(name: "Calendar display", url: "mailto:other@example.test", isCurrentUser: false)]))
        }
        let first = occurrence(offset: 0, email: "mailto:AMBER@example.test")
        let second = occurrence(offset: 86400, email: "mailto:amber@example.test")
        do {
            let store = try MinutesStore(dbPath: path)
            try store.savePerson(existing)
            try store.saveMeeting(Meeting(id: "call-1", title: "First"))
            _ = try CalendarMeetingBinder.bind(meetingId: "call-1", event: first, store: store)
        }
        let reloaded = try MinutesStore(dbPath: path)
        try reloaded.saveMeeting(Meeting(id: "call-2", title: "Second"))
        _ = try CalendarMeetingBinder.bind(meetingId: "call-2", event: second, store: reloaded)
        let firstIDs = Set(reloaded.listPeopleForMeeting(meetingId: "call-1").map(\.id))
        let secondIDs = Set(reloaded.listPeopleForMeeting(meetingId: "call-2").map(\.id))
        #expect(firstIDs == secondIDs && firstIDs.count == 2)
        #expect(firstIDs.contains(existing.id))
        #expect(reloaded.getPerson(id: existing.id)?.displayName == existing.displayName)
        #expect(reloaded.listPeople().count == 2)
        #expect(reloaded.getMeeting(id: "call-1")?.calendarEventId != reloaded.getMeeting(id: "call-2")?.calendarEventId)
        #expect(reloaded.listVoiceprints().isEmpty, "Invitee email is context, not acoustic identity or voice enrollment")
    }
}
