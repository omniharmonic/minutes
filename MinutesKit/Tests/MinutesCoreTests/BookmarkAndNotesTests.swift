import Testing
import Foundation
import MinutesCore
import MinutesSummarize

@Suite("Gate M2: Bookmarks, User Notes, and Grounded Summaries")
struct BookmarkAndNotesTests {
    
    @Test("Store handles Bookmark CRUD with timestamp ordering")
    func testBookmarkCRUD() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let store = try MinutesStore(dbPath: tempDir.appendingPathComponent("test.db").path)
        let meeting = Meeting(id: "m_notes_test", title: "Notes & Bookmarks Meeting")
        try store.saveMeeting(meeting)
        
        let b1 = Bookmark(id: "b1", meetingId: meeting.id, timestamp: 42.5, label: "Decision reached")
        let b2 = Bookmark(id: "b2", meetingId: meeting.id, timestamp: 12.0, label: "Introduction")
        let b3 = Bookmark(id: "b3", meetingId: meeting.id, timestamp: 95.0, label: "Action items")
        
        try store.saveBookmark(b1)
        try store.saveBookmark(b2)
        try store.saveBookmark(b3)
        
        let list = store.listBookmarks(meetingId: meeting.id)
        #expect(list.count == 3)
        #expect(list[0].id == "b2") // Ordered by timestamp ASC
        #expect(list[0].timestamp == 12.0)
        #expect(list[1].id == "b1")
        #expect(list[1].timestamp == 42.5)
        #expect(list[2].id == "b3")
        #expect(list[2].timestamp == 95.0)
        
        // Delete a bookmark
        try store.deleteBookmark(id: "b1")
        let listAfterDelete = store.listBookmarks(meetingId: meeting.id)
        #expect(listAfterDelete.count == 2)
        #expect(!listAfterDelete.contains(where: { $0.id == "b1" }))
    }
    
    @Test("User notes persist on Meeting across reloads")
    func testUserNotesPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let store = try MinutesStore(dbPath: tempDir.appendingPathComponent("test.db").path)
        var meeting = Meeting(id: "m_user_notes", title: "Executive Strategy Review")
        meeting.userNotes = "- Discussed Q4 launch timeline\n- Agreed to prioritize local-first encryption\n- Need follow-up on audio taps"
        try store.saveMeeting(meeting)
        
        let fetched = store.getMeeting(id: "m_user_notes")
        #expect(fetched != nil)
        #expect(fetched?.userNotes == meeting.userNotes)
        
        // Update user notes
        var updated = fetched!
        updated.userNotes = updated.userNotes! + "\n- Added action item for Ben"
        try store.saveMeeting(updated)
        
        let reFetched = store.getMeeting(id: "m_user_notes")
        #expect(reFetched?.userNotes?.contains("Added action item for Ben") == true)
    }
}
