#if canImport(SwiftUI)
import Foundation
import SwiftUI
import MinutesCore
import MinutesSummarize

public enum MeetingLibraryScope: Hashable, Sendable {
    case all, unfiled, folder(String)
}

@available(macOS 15.0, iOS 18.0, *)
extension AppState {
    public var libraryMeetings: [Meeting] {
        switch libraryScope {
        case .all: return meetings
        case .unfiled: return meetings.filter { folderAssignments[$0.id]?.folderID == nil }
        case .folder(let id): return meetings.filter { folderAssignments[$0.id]?.folderID == id }
        }
    }
    public var libraryTitle: String {
        switch libraryScope {
        case .all: return "All Meetings"
        case .unfiled: return "Unfiled"
        case .folder(let id): return folders.first { $0.id == id }?.name ?? "Meetings"
        }
    }
    public func folderName(for meetingID: String) -> String {
        guard let id = folderAssignments[meetingID]?.folderID else { return "Unfiled" }
        return folders.first { $0.id == id }?.name ?? "Unfiled"
    }
    public func folderCount(_ folderID: String?) -> Int {
        meetings.filter { folderAssignments[$0.id]?.folderID == folderID }.count
    }
    public func selectLibrary(_ scope: MeetingLibraryScope) {
        libraryScope = scope
        selectedSection = .meetings
        guard !libraryMeetings.contains(where: { $0.id == selectedMeetingId }) else { return }
        if let first = libraryMeetings.first { selectMeeting(id: first.id) }
        else {
            selectedMeetingId = nil; currentMeeting = nil
            currentClusters = []; currentUtterances = []; currentAttendees = []
            currentSummary = nil; currentBookmarks = []
        }
    }
    func reloadFolderLibrary() {
        do {
            let savedFolders = try store.listFolders()
            let memberships = try store.listFolderMemberships()
            folders = savedFolders
            folderAssignments = Dictionary(uniqueKeysWithValues: memberships.map { ($0.meetingID, $0) })
            if case .folder(let id) = libraryScope, !folders.contains(where: { $0.id == id }) { libraryScope = .unfiled }
        } catch { folderFilingMessage = "Folders could not be loaded: \(error.localizedDescription)" }
    }
    public func createFolder(name: String, description: String = "") throws {
        _ = try store.createFolder(name: name, description: description)
        folderLibraryRevision += 1
        reloadFolderLibrary()
    }
    public func updateFolder(id: String, name: String, description: String) throws {
        try store.updateFolder(id: id, name: name, description: description)
        folderLibraryRevision += 1
        reloadFolderLibrary()
    }
    public func deleteFolder(id: String) throws {
        try store.deleteFolder(id: id)
        folderLibraryRevision += 1
        reloadFolderLibrary()
    }
    public func moveMeeting(_ meetingID: String, to folderID: String?) throws {
        try moveMeetings([meetingID], to: folderID)
    }
    public func moveMeetings(_ meetingIDs: [String], to folderID: String?) throws {
        guard !meetingIDs.isEmpty else { return }
        try store.withImmediateTransaction {
            for id in Set(meetingIDs).sorted() { try store.moveMeeting(id: id, toFolderID: folderID) }
        }
        folderLibraryRevision += 1
        reloadFolderLibrary()
    }

    func fileNewMeetingInSelectedFolder(id: String) throws {
        if case .folder(let folderID) = libraryScope {
            try store.moveMeeting(id: id, toFolderID: folderID)
        }
    }

    /// Explicit bulk organization never reconsiders a manual folder/Unfiled choice.
    public func organizeUnfiledMeetings() async {
        guard !isOrganizingFolders, !isRecording, !isProcessing, !isFinalizingRecording else { return }
        isOrganizingFolders = true
        defer { isOrganizingFolders = false }
        let ids = meetings.filter { folderAssignments[$0.id]?.folderID == nil && folderAssignments[$0.id]?.source != .manual }.map(\.id)
        var filed = 0
        for id in ids {
            guard !Task.isCancelled else { break }
            await automaticallyFileMeeting(id: id, requiresEnabled: false)
            if folderAssignments[id]?.folderID != nil { filed += 1 }
        }
        folderFilingMessage = "Filed \(filed) \(filed == 1 ? "meeting" : "meetings"). \(ids.count - filed) left in Unfiled."
    }

    func folderClassificationInput(for meeting: Meeting) -> FolderClassificationInput {
        let summary = store.getSummary(meetingId: meeting.id)
        let text = summary.map { $0.markdown.isEmpty ? $0.overview : $0.markdown } ?? ""
        // Bounded local context; never read audio or voice vectors for filing.
        let transcript = text.isEmpty ? store.listUtterances(meetingId: meeting.id).prefix(30).map(\.text).joined(separator: " ") : ""
        return FolderClassificationInput(title: meeting.title, summary: String(text.prefix(12_000)),
            notes: String(([meeting.userNotes ?? "", transcript].joined(separator: "\n")).prefix(12_000)))
    }

    func folderCandidates(definitions: [MeetingFolder], memberships: [MeetingFolderMembership], excluding meetingID: String) -> [FolderClassificationCandidate] {
        let latestMeetings = store.listMeetings()
        return definitions.map { folder in
            let exampleIDs = Set(memberships.filter { $0.folderID == folder.id && $0.source == .manual }.map(\.meetingID))
            let examples = latestMeetings.filter { exampleIDs.contains($0.id) && $0.id != meetingID }
                .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }.prefix(3).map { example in
                    let context = folderClassificationInput(for: example)
                    return String("\(context.title)\n\(context.summary)\n\(context.notes)".prefix(1_200))
                }
            return FolderClassificationCandidate(folder: folder, manualExamples: examples)
        }
    }

    func automaticallyFileMeeting(id: String, requiresEnabled: Bool = true) async {
        guard (!requiresEnabled || autoFileMeetingsEnabled), !folderFilingInFlight.contains(id) else { return }
        folderFilingInFlight.insert(id)
        defer { folderFilingInFlight.remove(id) }
        do {
            guard let meeting = store.getMeeting(id: id) else { return }
            let membership = try store.folderMembership(meetingID: id)
            guard membership?.source != .manual, membership?.folderID == nil else { return }
            let definitions = try store.listFolders()
            guard !definitions.isEmpty else { return }
            let memberships = try store.listFolderMemberships()
            let baselineRevision = folderLibraryRevision
            let input = folderClassificationInput(for: meeting)
            let candidates = folderCandidates(definitions: definitions, memberships: memberships, excluding: id)
            let result = await classifyMeetingFolder(input, candidates)
            guard !Task.isCancelled, (!requiresEnabled || autoFileMeetingsEnabled),
                  folderLibraryRevision == baselineRevision,
                  result.status == .matched, let folderID = result.folderID,
                  definitions.contains(where: { $0.id == folderID }) else {
                if result.status != .matched { folderFilingMessage = result.reason }
                return
            }
            var applied = false
            try store.withImmediateTransaction {
                guard let latest = store.getMeeting(id: id),
                      try store.listFolders() == definitions,
                      try store.listFolderMemberships() == memberships,
                      folderCandidates(definitions: definitions, memberships: memberships, excluding: id) == candidates else { return }
                let currentInput = folderClassificationInput(for: latest)
                guard currentInput.title == input.title, currentInput.summary == input.summary,
                      currentInput.notes == input.notes else { return }
                applied = try store.applyAutomaticFolder(meetingID: id, folderID: folderID,
                    expectedRevision: membership?.revision ?? 0)
            }
            if applied {
                reloadFolderLibrary()
                folderFilingMessage = "Filed in \(definitions.first(where: { $0.id == folderID })?.name ?? "a matching folder")."
            }
        } catch { folderFilingMessage = "Meeting saved in Unfiled. Folder matching failed: \(error.localizedDescription)" }
    }
}
#endif
