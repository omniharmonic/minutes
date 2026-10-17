import Foundation
import MinutesCore
import MinutesSummarize

@MainActor enum FolderCLI {
    static func run(arguments: [String], store: MinutesStore) async throws {
        if arguments.dropFirst(2).first == "seed" {
            let trailing = Array(arguments.dropFirst(3))
            guard trailing.isEmpty || (trailing.count == 2 && trailing[0] == "--data-dir" && !trailing[1].hasPrefix("--")) else { throw FolderCommandUsage.invalid }
            let created = try store.seedStarterFoldersIfNeeded()
            print(created ? "Created Work, Personal and Learning folders. Existing meetings are unchanged." : "Folder setup was already initialized or existing folders were preserved. No folders were added.")
            return
        }
        let options = try FolderCommandOptions(arguments: Array(arguments.dropFirst(2)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func emit<T: Encodable>(_ value: T) throws { print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        switch options.action {
        case .list:
            let counts = try store.folderCounts()
            let entries = try store.listFolders().map { FolderListEntry(folder: $0, meetingCount: counts[$0.id] ?? 0) }
            try emit(FolderList(folders: entries, unfiledCount: try store.unfiledMeetingCount()))
        case .create:
            try emit(store.createFolder(name: options.name!, description: options.description ?? ""))
        case .update:
            guard let folder = try store.listFolders().first(where: { $0.id == options.targetID }) else { throw MeetingFolderError.missingFolder }
            try store.updateFolder(id: folder.id, name: options.name ?? folder.name, description: options.description ?? folder.description)
            print("Folder updated; meeting membership is unchanged.")
        case .delete:
            try store.deleteFolder(id: options.targetID!)
            print("Folder deleted. Its meetings remain in Unfiled and are protected from automatic filing.")
        case .move:
            try store.moveMeeting(id: options.targetID!, toFolderID: options.folderID)
            print("Meeting moved manually. Automatic filing will preserve this choice.")
        case .meetings:
            try emit(store.listMeetings(inFolderID: options.folderID))
        case .classify:
            guard let meeting = store.getMeeting(id: options.targetID!) else { throw MeetingFolderError.missingMeeting }
            let revision = try store.filingRevision(meetingID: meeting.id)
            let input = classificationInput(meeting: meeting, store: store)
            let candidates = try classificationCandidates(store: store, excluding: meeting.id)
            let result = await FolderClassifier().classify(input: input, candidates: candidates)
            var applied = false
            if options.apply, let folderID = result.folderID {
                try store.withImmediateTransaction {
                    guard let current = store.getMeeting(id: meeting.id),
                          classificationInput(meeting: current, store: store) == input,
                          try classificationCandidates(store: store, excluding: meeting.id) == candidates else { return }
                    applied = try store.applyAutomaticFolder(meetingID: meeting.id, folderID: folderID, expectedRevision: revision)
                }
            }
            try emit(ClassificationOutput(folderID: result.folderID, status: result.status.rawValue, reason: result.reason, similarity: result.similarity, margin: result.margin, applied: applied))
        }
    }
    private static func classificationInput(meeting: Meeting, store: MinutesStore) -> FolderClassificationInput {
        FolderClassificationInput(title: meeting.title, summary: store.getSummary(meetingId: meeting.id)?.overview ?? "", notes: meeting.userNotes ?? "")
    }
    private static func classificationCandidates(store: MinutesStore, excluding meetingID: String) throws -> [FolderClassificationCandidate] {
        let memberships = try store.listFolderMemberships()
        let meetings = store.listMeetings()
        return try store.listFolders().map { folder in
            let manualIDs = Set(memberships.filter { $0.folderID == folder.id && $0.source == .manual && $0.meetingID != meetingID }.map(\.meetingID))
            let examples = meetings.filter { manualIDs.contains($0.id) }.prefix(3).map { meeting in
                [meeting.title, store.getSummary(meetingId: meeting.id)?.overview ?? "", meeting.userNotes ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
            }
            return FolderClassificationCandidate(folder: folder, manualExamples: examples)
        }
    }
    private struct FolderListEntry: Encodable { let folder: MeetingFolder; let meetingCount: Int }
    private struct FolderList: Encodable { let folders: [FolderListEntry]; let unfiledCount: Int }
    private struct ClassificationOutput: Encodable {
        let folderID: String?; let status: String; let reason: String
        let similarity: Double?; let margin: Double?; let applied: Bool
    }
}
