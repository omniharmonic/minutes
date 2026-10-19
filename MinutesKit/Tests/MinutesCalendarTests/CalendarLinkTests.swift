import Foundation
import Testing
import MinutesCore
@testable import MinutesCalendar

private let nine30 = Date(timeIntervalSince1970: 1_792_427_400)
private let invitee = CalendarMeetingAttendee(displayName: "Ada", email: "ada@example.com", isCurrentUser: false, isOrganizer: false, responseStatus: "accepted")

private func event(_ id: String, start: TimeInterval, minutes: Double, attendees: [CalendarMeetingAttendee] = [invitee]) -> CalendarMeetingEvent {
    CalendarMeetingEvent(eventIdentifier: id, calendarIdentifier: "cal", title: id,
        start: nine30.addingTimeInterval(start), end: nine30.addingTimeInterval(start + minutes * 60), attendees: attendees)
}

struct CalendarLinkTests {
    @Test("A restart three minutes into the only invited meeting attaches that meeting")
    func restartAttachesOngoingEvent() {
        let tactical = event("Product Tactical", start: 0, minutes: 30)
        #expect(CalendarMeetingEvent.inProgress(in: [tactical], now: nine30.addingTimeInterval(227))?.id == tactical.id)
    }

    @Test("Overlapping invited meetings, solo blocks and finished events are never guessed")
    func ambiguousOrUninvitedEventsAreSkipped() {
        let now = nine30.addingTimeInterval(600)
        #expect(CalendarMeetingEvent.inProgress(in: [event("A", start: 0, minutes: 30), event("B", start: 300, minutes: 30)], now: now) == nil)
        #expect(CalendarMeetingEvent.inProgress(in: [event("Focus", start: 0, minutes: 60, attendees: [])], now: now) == nil)
        #expect(CalendarMeetingEvent.inProgress(in: [event("Earlier", start: -3_600, minutes: 30)], now: now) == nil)
        #expect(CalendarMeetingEvent.inProgress(in: [event("Soon", start: 240 + 600, minutes: 30)], now: now)?.title == "Soon")
    }

    @Test("Events overlapping a saved recording are listed longest overlap first")
    func overlappingEventsRanked() {
        let tactical = event("Product Tactical", start: 0, minutes: 45)
        let standup = event("Standup", start: -1_200, minutes: 25)
        let tomorrow = event("Tomorrow", start: 86_400, minutes: 30)
        let ranked = CalendarMeetingEvent.overlapping([standup, tomorrow, tactical], start: nine30.addingTimeInterval(227), end: nine30.addingTimeInterval(227 + 2_260))
        #expect(ranked.map(\.title) == ["Product Tactical", "Standup"])
    }
}
