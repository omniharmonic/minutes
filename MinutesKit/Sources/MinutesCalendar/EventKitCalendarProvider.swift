import Foundation
import EventKit

@MainActor
public protocol CalendarProviding {
    var hasAccess: Bool { get }
    func requestAccess() async throws
    func events(in interval: DateInterval) throws -> [CalendarMeetingEvent]
}

/// Read-only access to accounts configured in Apple Calendar; no direct Google OAuth.
@MainActor
public final class EventKitCalendarProvider: CalendarProviding {
    private let store = EKEventStore()
    public init() {}
    public var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public func requestAccess() async throws {
        if hasAccess { return }
        guard try await store.requestFullAccessToEvents() else { throw CalendarAccessError.permissionRequired }
    }

    public func events(in interval: DateInterval) throws -> [CalendarMeetingEvent] {
        guard hasAccess else { throw CalendarAccessError.permissionRequired }
        guard interval.duration > 0, interval.duration <= 31 * 86400 else { throw CalendarAccessError.invalidInterval }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate).compactMap { event -> CalendarMeetingEvent? in
            guard let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
            let participants = (event.attendees ?? []).map(Self.participant)
            let organizer = event.organizer.map(Self.participant)
            let conferenceText = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
            return CalendarMeetingEvent(eventIdentifier: identifier, calendarIdentifier: event.calendar.calendarIdentifier,
                title: event.title ?? "Untitled event", start: start, end: end, isAllDay: event.isAllDay,
                isCancelled: event.status == .canceled,
                attendees: CalendarParticipantMapper.map(participants, organizer: organizer),
                conferenceURL: ConferenceLinkParser.parseConferenceURL(from: conferenceText))
        }
        return CalendarMeetingEvent.scoped(events, interval: interval)
    }

    private static func participant(_ value: EKParticipant) -> CalendarParticipant {
        let response: String
        switch value.participantStatus {
        case .accepted: response = "accepted"
        case .declined: response = "declined"
        case .tentative: response = "tentative"
        case .pending: response = "pending"
        default: response = "unknown"
        }
        return CalendarParticipant(name: value.name, url: value.url.absoluteString,
            isCurrentUser: value.isCurrentUser, responseStatus: response)
    }
}
