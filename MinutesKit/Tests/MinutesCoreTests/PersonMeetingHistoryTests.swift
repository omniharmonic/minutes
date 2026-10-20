import Foundation
import Testing
@testable import MinutesCore

struct PersonMeetingHistoryTests {
    @Test("Person history reloads email-linked calls, distinguishes evidence and avoids duplicate meetings")
    func persistentContextsAreDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-person-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        do {
            let store = try MinutesStore(dbPath: path)
            try store.savePerson(Person(id: "p", displayName: "Same display name", emails: ["fixture@example.test", "alias@example.test"]))
            try store.savePerson(Person(id: "other", displayName: "Same display name", emails: ["other@example.test"]))
            for (index, id) in ["call-1", "call-2", "recognized-only", "suggested-only", "unrelated"].enumerated() {
                try store.saveMeeting(Meeting(id: id, title: id, startedAt: Date(timeIntervalSince1970: Double(index + 1) * 1000), endedAt: Date(timeIntervalSince1970: Double(index + 1) * 1000 + 60)))
            }
            try store.saveMeetingAttendees([
                MeetingAttendee(meetingId: "call-1", personId: "p", email: "fixture@example.test"),
                MeetingAttendee(meetingId: "call-2", personId: "p", email: "fixture@example.test"),
                MeetingAttendee(meetingId: "call-2", personId: "p", email: "alias@example.test"),
                MeetingAttendee(meetingId: "unrelated", personId: "other", email: "other@example.test")])
            for (id, meeting, person, assignment) in [("c1", "call-2", "p", "user"), ("c2", "call-2", "p", "auto"),
                ("c3", "recognized-only", "p", "auto"), ("c4", "suggested-only", "p", "suggested"), ("c5", "unrelated", "other", "user")] {
                try store.saveSpeakerClusters([SpeakerCluster(id: id, meetingId: meeting, trackId: "t", label: "Same display name", personId: person, assignment: assignment)])
            }
        }
        let reloaded = try MinutesStore(dbPath: path)
        let history = try reloaded.listMeetings(forPersonId: "p")
        #expect(history.map(\.id) == ["suggested-only", "recognized-only", "call-2", "call-1"])
        let invitee = try #require(history.first { $0.id == "call-1" })
        #expect(invitee.calendarInvitee && !invitee.speakerLinked && !invitee.confirmedSpeaker && !invitee.recognizedSpeaker)
        #expect(invitee.meeting.startedAt == Date(timeIntervalSince1970: 1000))
        #expect(invitee.meeting.endedAt == Date(timeIntervalSince1970: 1060))
        let both = try #require(history.first { $0.id == "call-2" })
        #expect(both.calendarInvitee && both.confirmedSpeaker && both.recognizedSpeaker && both.speakerLinked)
        let recognized = try #require(history.first { $0.id == "recognized-only" })
        #expect(!recognized.calendarInvitee && recognized.recognizedSpeaker && !recognized.confirmedSpeaker)
        let suggested = try #require(history.first { $0.id == "suggested-only" })
        #expect(suggested.speakerLinked && !suggested.confirmedSpeaker && !suggested.recognizedSpeaker)
        #expect(try reloaded.listMeetings(forPersonId: "missing").isEmpty)
        #expect(try reloaded.listMeetings(forPersonId: "p", limit: 1).map(\.id) == ["suggested-only"])
        #expect(reloaded.listVoiceprints().isEmpty)
    }

    @Test("History honours its limit, returns the full history on request, and orders equal dates deterministically")
    func queryLimitAndOrdering() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.savePerson(Person(id: "p", displayName: "Fixture"))
        for index in 0..<105 {
            let id = String(format: "m-%03d", index)
            try store.saveMeeting(Meeting(id: id, title: id, startedAt: Date(timeIntervalSince1970: 1000)))
            try store.saveMeetingAttendees([MeetingAttendee(meetingId: id, personId: "p", email: "fixture@example.test")])
        }
        let latest = try store.listMeetings(forPersonId: "p")
        #expect(latest.count == 100)
        #expect(latest.first?.id == "m-000" && latest.last?.id == "m-099")
        let full = try store.listMeetings(forPersonId: "p", limit: .max)
        #expect(full.count == 105 && full.last?.id == "m-104")
        #expect(try store.listMeetings(forPersonId: "p", limit: 0).isEmpty)
        #expect(try store.listMeetings(forPersonId: "p", limit: -1).isEmpty)
    }
}
