import Foundation
import Testing
@testable import MinutesCore

struct MeetingFolderTests {
    @Test("Folders survive reload and rename while membership follows stable IDs")
    func persistentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-folders-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        var folderID = ""
        do {
            let store = try MinutesStore(dbPath: path)
            try store.saveMeeting(Meeting(id: "a", title: "Budget review", userNotes: "Preserve notes"))
            let folder = try store.createFolder(name: "Finance", description: "Budgets and invoices")
            folderID = folder.id
            try store.moveMeeting(id: "a", toFolderID: folder.id)
            try store.updateFolder(id: folder.id, name: "Money", description: "Accounts and spending")
        }
        let store = try MinutesStore(dbPath: path)
        #expect(try store.listFolders().map(\.name) == ["Money"])
        #expect(try store.folderForMeeting(id: "a")?.id == folderID)
        #expect(try store.listMeetings(inFolderID: folderID).map(\.id) == ["a"])
        #expect(try store.folderCounts()[folderID] == 1)
        #expect(try store.unfiledMeetingCount() == 0)
        #expect(try store.listFolderMemberships().first?.source == .manual)
        try store.deleteFolder(id: folderID)
        #expect(try store.listMeetings(inFolderID: nil).map(\.id) == ["a"])
        #expect(store.getMeeting(id: "a")?.userNotes == "Preserve notes")
        #expect(try store.folderMembership(meetingID: "a")?.source == .manual)
    }

    @Test("Automatic filing cannot override manual moves, explicit Unfiled, deleted folders, or stale revisions")
    func compareAndSetProtectsManualChoices() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "m", title: "Review"))
        let a = try store.createFolder(name: "A", description: "First")
        let b = try store.createFolder(name: "B", description: "Second")
        #expect(try store.filingRevision(meetingID: "m") == 0)
        #expect(try store.applyAutomaticFolder(meetingID: "m", folderID: a.id, expectedRevision: 0))
        #expect(!(try store.applyAutomaticFolder(meetingID: "m", folderID: b.id, expectedRevision: 0)))
        let revision = try store.filingRevision(meetingID: "m")
        try store.moveMeeting(id: "m", toFolderID: nil)
        #expect(!(try store.applyAutomaticFolder(meetingID: "m", folderID: b.id, expectedRevision: revision)))
        #expect(!(try store.applyAutomaticFolder(meetingID: "m", folderID: b.id, expectedRevision: revision + 1)))
        #expect(try store.folderForMeeting(id: "m") == nil)
        try store.deleteFolder(id: b.id)
        #expect(!(try store.applyAutomaticFolder(meetingID: "m", folderID: b.id, expectedRevision: revision + 1)))
        #expect(try store.listFolderMemberships().count == 1)
    }

    @Test("Invalid folder changes are atomic and never delete meetings")
    func invalidChangesLeaveData() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "m", title: "Review"))
        let folder = try store.createFolder(name: "Work", description: "Projects")
        #expect(throws: (any Error).self) { try store.createFolder(name: "  ", description: "") }
        #expect(throws: (any Error).self) { try store.moveMeeting(id: "m", toFolderID: "missing") }
        #expect(throws: (any Error).self) { try store.moveMeeting(id: "missing", toFolderID: folder.id) }
        #expect(try store.listFolders().count == 1)
        #expect(try store.listFolderMemberships().isEmpty)
        #expect(try store.unfiledMeetingCount() == 1)
    }
}
