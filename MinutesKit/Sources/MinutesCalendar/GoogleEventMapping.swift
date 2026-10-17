import Foundation

struct GoogleEventsPage: Decodable {
    let items: [GoogleEvent]
    let nextPageToken: String?
    private enum CodingKeys: CodingKey { case items, nextPageToken }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([GoogleEvent].self, forKey: .items) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}
struct GoogleEvent: Decodable {
    struct Time: Decodable { let dateTime: String?; let date: String? }
    struct Person: Decodable {
        let email: String?; let displayName: String?; let isSelf: Bool?; let responseStatus: String?
        enum CodingKeys: String, CodingKey { case email, displayName, isSelf = "self", responseStatus }
        var participant: CalendarParticipant {
            CalendarParticipant(name: displayName, url: email.map { "mailto:" + $0 } ?? "", isCurrentUser: isSelf ?? false, responseStatus: responseStatus ?? "unknown")
        }
    }
    struct Conference: Decodable {
        struct Entry: Decodable { let entryPointType: String?; let uri: String? }
        let entryPoints: [Entry]?
    }
    let id: String
    let status: String?
    let summary: String?
    let start: Time?
    let end: Time?
    let attendees: [Person]?
    let organizer: Person?
    let hangoutLink: String?
    let conferenceData: Conference?

    func snapshot(calendarID: String) -> CalendarMeetingEvent? {
        guard status != "cancelled", let rawStart = start?.dateTime, let rawEnd = end?.dateTime,
              let start = Self.parse(rawStart), let end = Self.parse(rawEnd), start < end else { return nil }
        let candidates = [hangoutLink] + (conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.map(\.uri)
        let conference = candidates.compactMap { $0 }.first { value in
            guard let url = URL(string: value) else { return false }
            return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
        }
        return CalendarMeetingEvent(eventIdentifier: id, calendarIdentifier: "google:" + calendarID,
            title: summary?.isEmpty == false ? summary! : "Untitled meeting", start: start, end: end,
            attendees: CalendarParticipantMapper.map((attendees ?? []).map(\.participant), organizer: organizer?.participant), conferenceURL: conference)
    }
    private static func parse(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: value)
    }
}
