import Foundation

/// A local meeting's association with a stable person ID. Calendar attendance
/// is context only; it does not establish that this person spoke.
public struct PersonMeetingHistoryEntry: Codable, Sendable, Identifiable {
    public let meeting: Meeting
    public let calendarInvitee: Bool
    public let confirmedSpeaker: Bool
    public let recognizedSpeaker: Bool
    public let speakerLinked: Bool
    public var id: String { meeting.id }

    public init(meeting: Meeting, calendarInvitee: Bool, confirmedSpeaker: Bool, recognizedSpeaker: Bool, speakerLinked: Bool) {
        self.meeting = meeting
        self.calendarInvitee = calendarInvitee
        self.confirmedSpeaker = confirmedSpeaker
        self.recognizedSpeaker = recognizedSpeaker
        self.speakerLinked = speakerLinked
    }
}
