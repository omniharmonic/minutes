import Foundation
import Testing
@testable import MinutesCore

@Suite struct MeetingTrashTests {
    @Test func trashSurvivesRestartAndRestoresContentAndFolder() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let store = try MinutesStore(dbPath: path)
        let audio = NSTemporaryDirectory() + UUID().uuidString + ".wav"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: audio))
        let meeting = Meeting(id: "kept", title: "Synthetic", status: "needs_review", userNotes: "Keep notes", audioPath: audio)
        try store.saveMeeting(meeting)
        try store.saveUtterances([Utterance(id: 1, meetingId: meeting.id, clusterId: "a", speakerName: "Speaker 1", start: 0, end: 1, text: "Find this later")])
        let folder = try store.createFolder(name: "Research")
        try store.moveMeeting(id: meeting.id, toFolderID: folder.id)
        try store.trashMeeting(id: meeting.id)
        try store.trashMeeting(id: meeting.id)
        #expect(store.listMeetings().isEmpty)
        #expect(try store.folderCounts()[folder.id] == 0)
        #expect(try store.listMeetings(inFolderID: folder.id).isEmpty)
        let reopened = try MinutesStore(dbPath: path)
        #expect(reopened.listMeetings(inTrash: true).map(\.id) == [meeting.id])
        #expect(reopened.getMeeting(id: meeting.id)?.userNotes == "Keep notes")
        #expect(reopened.listUtterances(meetingId: meeting.id).first?.text == "Find this later")
        #expect(try Data(contentsOf: URL(fileURLWithPath: audio)) == Data([1, 2, 3]))
        try reopened.restoreMeeting(id: meeting.id)
        #expect(reopened.listMeetings().map(\.id) == [meeting.id])
        #expect(reopened.listMeetings(inTrash: true).isEmpty)
        #expect(try reopened.folderCounts()[folder.id] == 1)
        #expect(try reopened.folderMembership(meetingID: meeting.id)?.source == .manual)
    }
    @Test func activeMeetingCannotBeTrashed() throws {
        let store = try MinutesStore(dbPath: NSTemporaryDirectory() + UUID().uuidString + ".db")
        for status in ["starting", "recording", "processing", "transcribing", "diarizing", "summarizing"] {
            try store.saveMeeting(Meeting(id: status, title: status, status: status))
            #expect(throws: (any Error).self) { try store.trashMeeting(id: status) }
        }
        #expect(store.listMeetings(inTrash: true).isEmpty)
    }
}
