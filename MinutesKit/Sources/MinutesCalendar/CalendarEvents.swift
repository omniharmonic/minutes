import Foundation
import CryptoKit
import MinutesCore

public struct CalendarParticipant: Sendable {
    public let name: String?
    public let url: String
    public let isCurrentUser: Bool
    public let responseStatus: String
    public init(name: String?, url: String, isCurrentUser: Bool, responseStatus: String = "unknown") {
        self.name = name; self.url = url; self.isCurrentUser = isCurrentUser; self.responseStatus = responseStatus
    }
}

public struct CalendarMeetingAttendee: Codable, Sendable, Equatable, Identifiable {
    public let displayName: String
    public let email: String?
    public let isCurrentUser: Bool
    public var isOrganizer: Bool
    public let responseStatus: String
    public var id: String { email ?? displayName }
}

public enum CalendarParticipantMapper {
    public static func map(_ participants: [CalendarParticipant], organizer: CalendarParticipant? = nil) -> [CalendarMeetingAttendee] {
        var result: [CalendarMeetingAttendee] = []
        for participant in participants + (organizer.map { [$0] } ?? []) {
            let raw = participant.url
            let email: String? = raw.lowercased().hasPrefix("mailto:") ? {
                let value = String(raw.dropFirst(7)).components(separatedBy: "?")[0].removingPercentEncoding ?? ""
                let cleaned = NameResolver.cleanEmail(value)
                return cleaned.contains("@") && !cleaned.contains(",") ? cleaned : nil
            }() : nil
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name?.isEmpty == false ? name! : email.map(NameResolver.resolveDisplayName) ?? "Unknown invitee"
            let isOrganizer = organizer?.url.caseInsensitiveCompare(raw) == .orderedSame
            if let index = result.firstIndex(where: { email != nil && $0.email == email }) {
                let previous = result[index]
                // Organizer metadata often repeats an invitee with an unknown
                // response. Enrich identity context without erasing their RSVP.
                result[index] = CalendarMeetingAttendee(
                    displayName: previous.displayName == email.map(NameResolver.resolveDisplayName) && name?.isEmpty == false ? displayName : previous.displayName,
                    email: email, isCurrentUser: previous.isCurrentUser || participant.isCurrentUser,
                    isOrganizer: previous.isOrganizer || isOrganizer,
                    responseStatus: previous.responseStatus == "unknown" ? participant.responseStatus : previous.responseStatus)
            } else {
                result.append(CalendarMeetingAttendee(displayName: displayName, email: email,
                    isCurrentUser: participant.isCurrentUser, isOrganizer: isOrganizer, responseStatus: participant.responseStatus))
            }
        }
        return result
    }
}

public struct CalendarMeetingEvent: Codable, Sendable, Equatable, Identifiable {
    public let eventIdentifier: String
    public let calendarIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let isCancelled: Bool
    public let attendees: [CalendarMeetingAttendee]
    public let conferenceURL: String?
    /// Include the occurrence start: recurring meetings must not share suppression/binding IDs.
    public let id: String

    public init(eventIdentifier: String, calendarIdentifier: String, title: String, start: Date, end: Date,
        isAllDay: Bool = false, isCancelled: Bool = false, attendees: [CalendarMeetingAttendee] = [], conferenceURL: String? = nil) {
        self.eventIdentifier = eventIdentifier; self.calendarIdentifier = calendarIdentifier
        self.id = "\(calendarIdentifier):\(eventIdentifier):\(start.timeIntervalSince1970)"
        self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.isCancelled = isCancelled
        self.attendees = attendees; self.conferenceURL = conferenceURL
    }

    public static func scoped(_ events: [Self], interval: DateInterval) -> [Self] {
        events.filter { !$0.isAllDay && !$0.isCancelled && $0.start < $0.end && $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    /// The meeting a recording started without a calendar choice most likely
    /// belongs to: the only invited event in progress (or starting within five
    /// minutes). Overlapping events are ambiguous and return nil.
    public static func inProgress(in events: [Self], now: Date) -> Self? {
        let candidates = scoped(events, interval: DateInterval(start: now, duration: 301))
            .filter { $0.start.addingTimeInterval(-300) <= now && $0.end > now && !$0.attendees.isEmpty }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Events a finished recording could belong to, longest overlap first.
    public static func overlapping(_ events: [Self], start: Date, end: Date) -> [Self] {
        let interval = DateInterval(start: start.addingTimeInterval(-900), end: max(end, start) + 900)
        func overlap(_ event: Self) -> TimeInterval { min(event.end, max(end, start)).timeIntervalSince(max(event.start, start)) }
        return scoped(events, interval: interval).sorted { overlap($0) > overlap($1) }
    }

    public static func nextPrompt(in events: [Self], now: Date, suppressedIDs: Set<String>) -> Self? {
        scoped(events, interval: DateInterval(start: now.addingTimeInterval(-120), duration: 240))
            .first { abs($0.start.timeIntervalSince(now)) <= 120 && $0.end > now && !suppressedIDs.contains($0.id) }
    }
}

public enum CalendarAccessError: Error, LocalizedError {
    case permissionRequired
    case invalidInterval
    case missingMeeting
    case cancelledEvent
    public var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Calendar full access is required. Connect Calendar, or grant access in System Settings. Google accounts must already be added to Apple Calendar."
        case .invalidInterval: return "Choose a calendar interval longer than zero and no longer than 31 days."
        case .missingMeeting: return "The selected local meeting no longer exists."
        case .cancelledEvent: return "A cancelled event cannot be bound to a recording."
        }
    }
}

public enum CalendarMeetingBinder {
    @discardableResult
    public static func bind(meetingId: String, event: CalendarMeetingEvent, store: MinutesStore) throws -> Meeting {
        guard !event.isCancelled else { throw CalendarAccessError.cancelledEvent }
        var bound: Meeting?
        try store.withTransaction {
            guard var meeting = store.getMeeting(id: meetingId) else { throw CalendarAccessError.missingMeeting }
            meeting.calendarEventId = event.id
            meeting.title = event.title
            meeting.conferenceURL = event.conferenceURL
            var people = store.listPeople()
            var invitees: [MeetingAttendee] = []
            for attendee in event.attendees where attendee.responseStatus != "declined" {
                guard let email = attendee.email else { continue }
                let existing = people.first { $0.emails.contains { NameResolver.cleanEmail($0) == email } }
                var person = existing ?? Person(id: "calendar-" + SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined(),
                    displayName: attendee.displayName, isMe: attendee.isCurrentUser, emails: [email])
                person.isMe = person.isMe || attendee.isCurrentUser
                try store.savePerson(person)
                people.append(person)
                invitees.append(MeetingAttendee(meetingId: meetingId, personId: person.id, email: email,
                    name: attendee.displayName, isOrganizer: attendee.isOrganizer, responseStatus: attendee.responseStatus))
            }
            try store.saveMeeting(meeting)
            try store.replaceMeetingAttendees(meetingId: meetingId, attendees: invitees)
            bound = meeting
        }
        return bound!
    }
}
