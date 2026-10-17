import Foundation
import Testing
@testable import MinutesCore

struct StarterFolderTests {
    @Test("Starter folders are created once without filing or rewriting existing meetings")
    func firstInitialization() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "saved", title: "Existing title", userNotes: "My unchanged draft"))
        #expect(try store.seedStarterFoldersIfNeeded())
        let first = try store.listFolders()
        #expect(first.map(\.name) == ["Work", "Personal", "Learning"])
        #expect(first.allSatisfy { !$0.description.isEmpty })
        #expect(!(try store.seedStarterFoldersIfNeeded()))
        #expect(try store.listFolders() == first)
        #expect(try store.listFolderMemberships().isEmpty)
        #expect(store.getMeeting(id: "saved")?.title == "Existing title")
        #expect(store.getMeeting(id: "saved")?.userNotes == "My unchanged draft")
    }

    @Test("Deleting every starter survives reopening without resurrecting defaults")
    func deletionIsPermanent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-starter-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        do {
            let store = try MinutesStore(dbPath: path)
            #expect(try store.seedStarterFoldersIfNeeded())
            for folder in try store.listFolders() { try store.deleteFolder(id: folder.id) }
        }
        let reopened = try MinutesStore(dbPath: path)
        #expect(!(try reopened.seedStarterFoldersIfNeeded()))
        #expect(try reopened.listFolders().isEmpty)
    }

    @Test("An existing custom library is initialized without adding or changing folders")
    func preservesCustomOrganization() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let custom = try store.createFolder(name: "My project", description: "Only my current project")
        let before = try store.listFolders()
        #expect(!(try store.seedStarterFoldersIfNeeded()))
        #expect(try store.listFolders() == before)
        try store.deleteFolder(id: custom.id)
        #expect(!(try store.seedStarterFoldersIfNeeded()))
        #expect(try store.listFolders().isEmpty)
    }

    @Test("Concurrent initializers on separate database connections cannot duplicate starter folders")
    func concurrentInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-starter-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        let first = try MinutesStore(dbPath: path)
        let second = try MinutesStore(dbPath: path)
        let results = try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { try first.seedStarterFoldersIfNeeded() }
            group.addTask { try second.seedStarterFoldersIfNeeded() }
            var values: [Bool] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(try first.listFolders().map(\.name) == ["Work", "Personal", "Learning"])
        #expect(try second.listFolders() == first.listFolders())
    }
}
