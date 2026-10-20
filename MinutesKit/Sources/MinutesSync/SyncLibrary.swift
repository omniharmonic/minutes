import Foundation
import MinutesCore

/// Kinds of records exchanged between a person's devices through their own
/// private iCloud database. Voiceprints, voice embeddings, export queues and
/// credentials are never part of a payload.
public enum SyncRecordKind: String, Sendable, CaseIterable {
    case folder = "Folder", person = "Person", meeting = "Meeting", audio = "Audio"
}

/// `Kind:id`, which is also the CloudKit record name.
public struct SyncRecordName: Hashable, Sendable, CustomStringConvertible {
    public let kind: SyncRecordKind
    public let id: String
    public init(kind: SyncRecordKind, id: String) { self.kind = kind; self.id = id }
    public init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":"), let kind = SyncRecordKind(rawValue: String(text[..<colon])) else { return nil }
        let id = String(text[text.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }
    public var description: String { "\(kind.rawValue):\(id)" }
}

/// Everything about one meeting that should look the same on every device.
/// Flat so a three-way merge can decide field by field.
struct MeetingSyncPayload: Codable {
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var platform: String
    var calendarEventId: String?
    var conferenceURL: String?
    var status: String
    var device: String?
    var userNotes: String?
    var inTrash: Bool
    var folderID: String?
    var attendees: [MeetingAttendee]
    var utterances: [Utterance]
    var summary: MeetingSummary?
    var bookmarks: [Bookmark]
    var clusters: [SpeakerCluster]
}

/// Describes an audio file so a change is noticed without reading it.
struct AudioSyncDescriptor: Codable { let bytes: Int64 }

public enum SyncChange: Hashable, Sendable {
    case save(SyncRecordName)
    case delete(SyncRecordName)
}

/// The outcome of applying a record that arrived from another device.
public struct SyncApplyResult: Sendable, Equatable {
    /// The local copy differs from what arrived (a merge kept local edits) and must be sent back.
    public let needsUpload: Bool
    public let changedLocalLibrary: Bool
}

/// Local half of sync: turns the library into payloads, notices local edits by
/// comparing against the last payload agreed with the server, and merges
/// arriving payloads three ways (base, local, remote).
public final class SyncLibrary: @unchecked Sendable {
    let store: MinutesStore
    /// Where audio from other devices is saved; nil when recordings do not sync.
    let audioDirectory: URL?
    /// Compressed recordings only; larger files stay on the device that made them.
    public static let maximumAudioBytes: Int64 = 250 * 1_024 * 1_024

    public init(store: MinutesStore, audioDirectory: URL? = nil) {
        self.store = store; self.audioDirectory = audioDirectory
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    // MARK: Local payloads

    /// Every record this device would share, folders and people before meetings.
    public func localRecordNames() throws -> [SyncRecordName] {
        var names = try store.listFolders().map { SyncRecordName(kind: .folder, id: $0.id) }
        names += store.listPeople().map { SyncRecordName(kind: .person, id: $0.id) }
        let meetings = store.listMeetings() + store.listMeetings(inTrash: true)
        names += meetings.filter(Self.isShareable).map { SyncRecordName(kind: .meeting, id: $0.id) }
        if audioDirectory != nil {
            names += meetings.filter { Self.isShareable($0) && syncableAudio(for: $0) != nil }.map { SyncRecordName(kind: .audio, id: $0.id) }
        }
        return names
    }

    /// Recordings still in progress stay local until they finish.
    static func isShareable(_ meeting: Meeting) -> Bool { !["recording", "processing"].contains(meeting.status) }

    /// The canonical payload for a record, or nil when it no longer exists here.
    public func localPayload(_ name: SyncRecordName) throws -> Data? {
        switch name.kind {
        case .folder:
            return try store.listFolders().first { $0.id == name.id }.map { try Self.encoder.encode($0) }
        case .person:
            return try store.getPerson(id: name.id).map { try Self.encoder.encode($0) }
        case .meeting:
            guard let meeting = store.getMeeting(id: name.id), Self.isShareable(meeting) else { return nil }
            return try Self.encoder.encode(meetingPayload(meeting))
        case .audio:
            guard audioDirectory != nil, let meeting = store.getMeeting(id: name.id), Self.isShareable(meeting),
                  !(try store.isMeetingInTrash(id: name.id)), let file = syncableAudio(for: meeting) else { return nil }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return try Self.encoder.encode(AudioSyncDescriptor(bytes: size))
        }
    }

    /// The file to upload for an audio record.
    public func audioFile(for meetingID: String) -> URL? {
        store.getMeeting(id: meetingID).flatMap(syncableAudio)
    }

    func syncableAudio(for meeting: Meeting) -> URL? {
        guard let path = meeting.audioPath, path.hasSuffix(".m4a"), meeting.platform != "transcript_import" else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, Int64(size) <= Self.maximumAudioBytes else { return nil }
        return url
    }

    private func meetingPayload(_ meeting: Meeting) throws -> MeetingSyncPayload {
        let clusters = store.listSpeakerClusters(meetingId: meeting.id).map { cluster -> SpeakerCluster in
            var shared = cluster
            shared.centroid = []
            shared.embeddingModel = nil
            return shared
        }
        return MeetingSyncPayload(title: meeting.title, startedAt: meeting.startedAt, endedAt: meeting.endedAt, platform: meeting.platform,
            calendarEventId: meeting.calendarEventId, conferenceURL: meeting.conferenceURL, status: meeting.status, device: meeting.device,
            userNotes: meeting.userNotes, inTrash: try store.isMeetingInTrash(id: meeting.id),
            folderID: try store.folderMembership(meetingID: meeting.id)?.folderID,
            attendees: store.listMeetingAttendees(meetingId: meeting.id).sorted { $0.email < $1.email },
            utterances: store.listUtterances(meetingId: meeting.id).sorted { $0.id < $1.id },
            summary: store.getSummary(meetingId: meeting.id),
            bookmarks: store.listBookmarks(meetingId: meeting.id).sorted { $0.id < $1.id },
            clusters: clusters.sorted { $0.id < $1.id })
    }

    // MARK: Change detection

    /// Records edited here since they were last agreed with the server, and
    /// records removed here that the server still has. Only records the
    /// database marked as changed are encoded.
    public func pendingChanges() throws -> [SyncChange] {
        var changes: [SyncChange] = []
        for text in try store.listSyncDirtyRecordNames() {
            guard let name = SyncRecordName(text) else { try store.clearSyncDirty(text); continue }
            // With recordings off, keep their marks for when they are turned on.
            if name.kind == .audio, audioDirectory == nil { continue }
            let base = try store.syncRecordState(text)?.basePayload
            if let payload = try localPayload(name) {
                if payload != base { changes.append(.save(name)); continue }
            } else if base != nil {
                let meetingGone = store.getMeeting(id: name.id) == nil
                switch name.kind {
                // Meetings still recording are absent but not deleted; recordings go with their meeting.
                case .meeting, .audio: if meetingGone { changes.append(.delete(name)); continue }
                case .folder, .person: changes.append(.delete(name)); continue
                }
            }
            try store.clearSyncDirty(text)
        }
        return changes
    }

    /// The server accepted `payload` for `name`.
    public func acknowledgeSaved(_ name: SyncRecordName, payload: Data, systemFields: Data?) throws {
        try store.saveSyncRecordState(name.description, basePayload: payload, systemFields: systemFields)
    }

    public func acknowledgeDeleted(_ name: SyncRecordName) throws {
        try store.deleteSyncRecordState(name.description)
    }

    public func systemFields(_ name: SyncRecordName) throws -> Data? {
        try store.syncRecordState(name.description)?.systemFields
    }

    /// Keeps CloudKit's newest change tag for a record, for example after a conflict.
    public func updateSystemFields(_ name: SyncRecordName, _ systemFields: Data) throws {
        try store.saveSyncRecordState(name.description, basePayload: nil, systemFields: systemFields)
    }

    /// Forget the server's change tag (for example the record vanished), keeping the merge base.
    public func clearSystemFields(_ name: SyncRecordName) throws {
        guard let state = try store.syncRecordState(name.description) else { return }
        try store.deleteSyncRecordState(name.description)
        if let base = state.basePayload { try store.saveSyncRecordState(name.description, basePayload: base, systemFields: nil) }
    }

    // MARK: Applying remote records

    /// Merges a record from another device into this library. `audioFile` is the
    /// downloaded recording for an audio record.
    @discardableResult
    public func applyRemote(_ name: SyncRecordName, payload remote: Data, systemFields: Data?, audioFile: URL? = nil) throws -> SyncApplyResult {
        if name.kind == .audio {
            // Recordings are written once. Agree on one only after its file is
            // saved here, so a recording that could not be saved yet arrives again.
            if try localPayload(name) == nil { try write(name, payload: remote, audioFile: audioFile) }
            guard try localPayload(name) != nil else { return SyncApplyResult(needsUpload: false, changedLocalLibrary: false) }
            try store.saveSyncRecordState(name.description, basePayload: try localPayload(name), systemFields: systemFields)
            return SyncApplyResult(needsUpload: false, changedLocalLibrary: true)
        }
        let base = try store.syncRecordState(name.description)?.basePayload
        let local = try localPayload(name)
        let merged: Data
        if let local, local != remote, local != base {
            merged = try Self.merge(kind: name.kind, base: base, local: local, remote: remote)
        } else {
            merged = remote
        }
        let changed = merged != local
        if changed { try write(name, payload: merged, audioFile: audioFile) }
        let stored = try localPayload(name) ?? merged
        try store.saveSyncRecordState(name.description, basePayload: remote, systemFields: systemFields)
        return SyncApplyResult(needsUpload: stored != remote, changedLocalLibrary: changed)
    }

    /// Another device deleted this record. Meetings go to Recently Deleted rather than vanishing.
    @discardableResult
    public func applyRemoteDeletion(_ name: SyncRecordName) throws -> Bool {
        switch name.kind {
        case .meeting:
            try store.deleteSyncRecordState(name.description)
            guard store.getMeeting(id: name.id) != nil else { return false }
            let trashed = try store.isMeetingInTrash(id: name.id)
            if !trashed { try store.trashMeeting(id: name.id) }
            // Remember the trashed copy as agreed, so it is not uploaded again
            // unless the person restores or edits it here.
            if let payload = try localPayload(name) { try store.saveSyncRecordState(name.description, basePayload: payload, systemFields: nil) }
            return !trashed
        case .folder:
            try store.deleteSyncRecordState(name.description)
            guard try store.listFolders().contains(where: { $0.id == name.id }) else { return false }
            try store.deleteFolder(id: name.id)
            return true
        case .person, .audio:
            try store.deleteSyncRecordState(name.description)
            // People stay linked to local meetings; local recordings stay where they are.
            return false
        }
    }

    private func write(_ name: SyncRecordName, payload: Data, audioFile: URL?) throws {
        switch name.kind {
        case .folder:
            let folder = try Self.decoder.decode(MeetingFolder.self, from: payload)
            try adoptDuplicateStarterFolder(folder)
            try store.upsertFolder(folder)
        case .person:
            try store.savePerson(try Self.decoder.decode(Person.self, from: payload))
        case .meeting:
            try writeMeeting(id: name.id, try Self.decoder.decode(MeetingSyncPayload.self, from: payload))
        case .audio:
            guard let audioFile, let directory = audioDirectory, var meeting = store.getMeeting(id: name.id) else { return }
            if let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) { return }
            let folder = directory.appendingPathComponent("synced", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(name.id).m4a")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: audioFile, to: destination)
            meeting.audioPath = destination.path
            try store.saveMeeting(meeting)
        }
    }

    /// Each device seeds the same starter folders with its own ids. When another
    /// device's folder arrives with a name this device has but never shared,
    /// meetings move into the arriving folder and the local duplicate goes.
    private func adoptDuplicateStarterFolder(_ folder: MeetingFolder) throws {
        let id = folder.id
        guard let duplicate = try store.listFolders().first(where: {
            $0.id != id && $0.name.compare(folder.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }), try store.syncRecordState(SyncRecordName(kind: .folder, id: duplicate.id).description) == nil else { return }
        let members = try store.listFolderMemberships().filter { $0.folderID == duplicate.id }.map(\.meetingID)
        try store.withImmediateTransaction {
            try store.upsertFolder(folder)
            for meetingID in members { try store.moveMeeting(id: meetingID, toFolderID: id) }
            try store.deleteFolder(id: duplicate.id)
        }
    }

    private func writeMeeting(id: String, _ payload: MeetingSyncPayload) throws {
        let existing = store.getMeeting(id: id)
        let meeting = Meeting(id: id, title: payload.title, startedAt: payload.startedAt, endedAt: payload.endedAt, platform: payload.platform,
            calendarEventId: payload.calendarEventId, conferenceURL: payload.conferenceURL, status: payload.status, device: payload.device,
            userNotes: payload.userNotes, audioPath: existing?.audioPath)
        try store.withImmediateTransaction {
            try store.saveMeeting(meeting)
            for person in payload.attendees.compactMap(\.personId) where store.getPerson(id: person) == nil {
                // The person record normally arrives first; keep the link either way.
                let attendee = payload.attendees.first { $0.personId == person }
                try store.savePerson(Person(id: person, displayName: attendee?.name ?? attendee?.email ?? "Invitee", emails: attendee.map { [$0.email] } ?? []))
            }
            try store.replaceMeetingAttendees(meetingId: id, attendees: payload.attendees)
            try store.replaceUtterances(meetingId: id, with: payload.utterances)
            try store.replaceSpeakerClusters(meetingId: id, with: payload.clusters)
            try store.replaceBookmarks(meetingId: id, with: payload.bookmarks)
            if let summary = payload.summary { try store.saveSummary(summary) }
            let currentFolder = try store.folderMembership(meetingID: id)?.folderID
            if currentFolder != payload.folderID {
                if let folder = payload.folderID, !(try store.listFolders().contains { $0.id == folder }) {
                    // The folder's own record is still on its way; it renames this placeholder.
                    try store.upsertFolder(MeetingFolder(id: folder, name: "Synced folder"))
                }
                try store.moveMeeting(id: id, toFolderID: payload.folderID)
            }
            let trashed = try store.isMeetingInTrash(id: id)
            if payload.inTrash && !trashed { try store.trashMeeting(id: id) }
            if !payload.inTrash && trashed { try store.restoreMeeting(id: id) }
        }
    }

    // MARK: Merge

    /// Field by field: a side that left a field as it was in `base` takes the
    /// other side's value. When both changed a field the remote value wins,
    /// except notes (both versions are kept) and moments (both sets are kept).
    static func merge(kind: SyncRecordKind, base: Data?, local: Data, remote: Data) throws -> Data {
        guard kind == .meeting || kind == .folder || kind == .person,
              let localObject = try JSONSerialization.jsonObject(with: local) as? [String: Any],
              let remoteObject = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else { return remote }
        let baseObject = base.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var result = remoteObject
        for key in Set(localObject.keys).union(remoteObject.keys) {
            let baseValue = baseObject[key], localValue = localObject[key], remoteValue = remoteObject[key]
            if same(localValue, remoteValue) || same(localValue, baseValue) { continue }
            if same(remoteValue, baseValue) { result[key] = localValue; continue }
            switch key {
            case "userNotes":
                let mine = (localValue as? String) ?? "", theirs = (remoteValue as? String) ?? ""
                result[key] = mine.isEmpty ? theirs : (theirs.isEmpty ? mine : mine + "\n\n— Edited on another device —\n" + theirs)
            case "bookmarks":
                result[key] = mergeByID(base: baseValue as? [[String: Any]] ?? [], local: localValue as? [[String: Any]] ?? [], remote: remoteValue as? [[String: Any]] ?? [])
            default:
                break
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    /// Union of both sides' additions minus both sides' removals.
    private static func mergeByID(base: [[String: Any]], local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        func ids(_ items: [[String: Any]]) -> Set<String> { Set(items.compactMap { $0["id"] as? String }) }
        let removed = ids(base).subtracting(ids(local)).union(ids(base).subtracting(ids(remote)))
        var seen = Set<String>()
        return (remote + local).filter { item in
            guard let id = item["id"] as? String, !removed.contains(id) else { return false }
            return seen.insert(id).inserted
        }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as AnyObject).isEqual(b)
        case (let a?, nil), (nil, let a?): return a is NSNull
        }
    }
}
