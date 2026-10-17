#if canImport(SwiftUI)
import Foundation
import MinutesCore

/// The same date sections are used by the Mac list and the iPhone library.
public struct MeetingDateGroup: Identifiable {
    public let title: String
    public let meetings: [Meeting]
    public var id: String { title }

    public static func sections(for meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let month = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let sorted = meetings.sorted { $0.startedAt > $1.startedAt }
        var groups: [Self] = []
        for meeting in sorted {
            let title: String
            if meeting.startedAt >= today { title = "Today" }
            else if meeting.startedAt >= yesterday { title = "Yesterday" }
            else if meeting.startedAt >= week { title = "Previous 7 Days" }
            else if meeting.startedAt >= month { title = "Previous 30 Days" }
            else { title = meeting.startedAt.formatted(.dateTime.month(.wide).year()) }
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = Self(title: title, meetings: last.meetings + [meeting])
            } else { groups.append(Self(title: title, meetings: [meeting])) }
        }
        return groups
    }
}
#endif
