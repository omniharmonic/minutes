import Foundation
import Testing
import MinutesCore
import MinutesSummarize
@testable import MinutesApp

private actor FolderMatchGate {
    var started = false
    var continuation: CheckedContinuation<FolderClassificationResult, Never>?
    func waitForResult() async -> FolderClassificationResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func finish(folderID: String) {
        continuation?.resume(returning: FolderClassificationResult(folderID: folderID, status: .matched, reason: "Fixture strong match", similarity: 0.95, margin: 0.4))
        continuation = nil
    }
}

@MainActor
struct FolderLibraryTests {
    private func fixture() throws -> (URL, MinutesStore, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-folder-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db.sqlite").path)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        return (root, store, preferences)
    }
    @Test("Library scopes and folder deletion preserve the meeting and explicit Unfiled choice")
    func scopesAndDeletion() throws {
        let (root, store, preferences) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(id: "folder-library", title: "Quarterly finance review")
        try store.saveMeeting(meeting)
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences)
        try state.createFolder(name: "Finance", description: "Budgets and accounts")
        let folder = try #require(state.folders.first { $0.name == "Finance" })
        try state.moveMeeting(meeting.id, to: folder.id)
        state.selectLibrary(.folder(folder.id))
        #expect(state.libraryTitle == "Finance")
        #expect(state.libraryMeetings.map(\.id) == [meeting.id])
        #expect(state.folderCount(folder.id) == 1)
        #expect(state.folderCount(nil) == 0)
        try state.deleteFolder(id: folder.id)
        #expect(state.libraryScope == .unfiled)
        #expect(state.libraryMeetings.map(\.id) == [meeting.id])
        #expect(state.folderName(for: meeting.id) == "Unfiled")
        #expect(try store.folderMembership(meetingID: meeting.id)?.source == .manual)
        #expect(store.getMeeting(id: meeting.id) != nil)
    }
    @Test("Automatic filing commits a strong result but never overrides manual Unfiled")
    func automaticAndManual() async throws {
        let (root, store, preferences) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(name: "Finance", description: "Budgets")
        let meeting = Meeting(id: "auto-file", title: "Quarterly budget planning and finance team review")
        try store.saveMeeting(meeting)
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences,
            classifyMeetingFolder: { _, candidates in
                #expect(candidates.map(\.folder.id).contains(folder.id))
                return FolderClassificationResult(folderID: folder.id, status: .matched, reason: "Fixture", similarity: 0.95, margin: 0.3)
            })
        await state.automaticallyFileMeeting(id: meeting.id)
        #expect(try store.folderMembership(meetingID: meeting.id)?.source == .automatic)
        #expect(state.folderCount(folder.id) == 1)
        try state.moveMeeting(meeting.id, to: nil)
        await state.automaticallyFileMeeting(id: meeting.id)
        #expect(try store.folderMembership(meetingID: meeting.id)?.folderID == nil)
        #expect(try store.folderMembership(meetingID: meeting.id)?.source == .manual)
    }
    @Test("In-flight matching cannot overwrite a manual move or newly edited note", arguments: [true, false])
    func racingEdits(manualMove: Bool) async throws {
        let (root, store, preferences) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(name: "Finance", description: "Budgets")
        var meeting = Meeting(id: "race-file", title: "Quarterly budget planning and finance review")
        try store.saveMeeting(meeting)
        let gate = FolderMatchGate()
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences,
            classifyMeetingFolder: { _, _ in await gate.waitForResult() })
        let work = Task { await state.automaticallyFileMeeting(id: meeting.id) }
        await gate.waitUntilStarted()
        if manualMove { try state.moveMeeting(meeting.id, to: nil) }
        else { meeting.userNotes = "The discussion is now about a different project."; try store.saveMeeting(meeting) }
        await gate.finish(folderID: folder.id)
        await work.value
        #expect(try store.folderMembership(meetingID: meeting.id)?.folderID == nil)
        if manualMove { #expect(try store.folderMembership(meetingID: meeting.id)?.source == .manual) }
        else { #expect(try store.folderMembership(meetingID: meeting.id) == nil) }
    }
    @Test("Multi-meeting moves roll back completely when a destination row cannot be moved")
    func batchMoveRollsBack() throws {
        let (root, store, preferences) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveMeeting(Meeting(id: "aa-valid", title: "A real meeting"))
        let folder = try store.createFolder(name: "Finance", description: "Budgets")
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences)
        #expect(throws: Error.self) { try state.moveMeetings(["aa-valid", "zz-missing"], to: folder.id) }
        #expect(try store.folderMembership(meetingID: "aa-valid") == nil)
        #expect(state.folderCount(folder.id) == 0)
    }
    @Test("Editing a manually filed example invalidates an in-flight automatic match")
    func staleExampleCannotFile() async throws {
        let (root, store, preferences) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(name: "Finance", description: "Budgets")
        let target = Meeting(id: "target", title: "Quarterly finance review and budget planning")
        var example = Meeting(id: "example", title: "Finance budget review", userNotes: "Discuss spending and quarterly forecasts.")
        try store.saveMeeting(target); try store.saveMeeting(example)
        try store.moveMeeting(id: example.id, toFolderID: folder.id)
        let gate = FolderMatchGate()
        let state = try AppState(store: store, audioDirectory: root, preferences: preferences,
            classifyMeetingFolder: { _, _ in await gate.waitForResult() })
        let work = Task { await state.automaticallyFileMeeting(id: target.id) }
        await gate.waitUntilStarted()
        example.userNotes = "The corrected notes concern a separate gardening project."
        try store.saveMeeting(example)
        await gate.finish(folderID: folder.id)
        await work.value
        #expect(try store.folderMembership(meetingID: target.id) == nil)
    }
}
