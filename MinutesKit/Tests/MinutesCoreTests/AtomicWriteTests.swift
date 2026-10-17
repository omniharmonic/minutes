import Foundation
import Testing
@testable import MinutesCore

struct AtomicWriteTests {
    private func environment() throws -> (MinutesStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-atomic-\(UUID()).sqlite")
        let store = try MinutesStore(dbPath: url.path)
        try store.saveMeeting(Meeting(id: "valid", title: "Valid"))
        return (store, url)
    }

    @Test("Cluster batch failure throws and rolls back preceding valid rows")
    func clusterRollback() throws {
        let (store, url) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try store.saveSpeakerClusters([
                SpeakerCluster(id: "one", meetingId: "valid", trackId: "t", label: "Valid"),
                SpeakerCluster(id: "two", meetingId: "missing", trackId: "t", label: "Invalid")])
        }
        #expect(store.listSpeakerClusters(meetingId: "valid").isEmpty)
    }

    @Test("Utterance batch failure throws and rolls back preceding valid rows")
    func utteranceRollback() throws {
        let (store, url) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try store.saveUtterances([
                Utterance(id: 1, meetingId: "valid", clusterId: "c", speakerName: "", start: 0, end: 1, text: "Keep safe"),
                Utterance(id: 2, meetingId: "missing", clusterId: "c", speakerName: "", start: 1, end: 2, text: "Invalid")])
        }
        #expect(store.listUtterances(meetingId: "valid").isEmpty)
    }

    @Test("Attendee batch failure throws and rolls back preceding valid rows")
    func attendeeRollback() throws {
        let (store, url) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try store.saveMeetingAttendees([
                MeetingAttendee(meetingId: "valid", email: "one@example.com"),
                MeetingAttendee(meetingId: "missing", email: "two@example.com")])
        }
        #expect(store.listMeetingAttendees(meetingId: "valid").isEmpty)
    }

    @Test("Summary constraint failure is surfaced")
    func summaryFailure() throws {
        let (store, url) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try store.saveSummary(MeetingSummary(meetingId: "missing", title: "Invalid", overview: ""))
        }
    }
}
