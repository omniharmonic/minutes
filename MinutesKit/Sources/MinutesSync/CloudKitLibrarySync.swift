#if canImport(CloudKit)
import Foundation
import CloudKit
import os
import MinutesCore

/// What Settings shows about sync. Never contains meeting content.
public struct LibrarySyncStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, syncing, signedOut, failed(String), removedFromICloud }
    public var phase: Phase
    public var lastSynced: Date?
    public var pendingCount: Int
}

/// Moves the library between a person's devices through their private iCloud
/// database (free to the developer; it uses the person's own iCloud storage).
/// `CKSyncEngine` schedules work, retries and tracks account changes; this
/// type maps `SyncLibrary` records to CloudKit records in one custom zone.
@available(macOS 14.0, iOS 17.0, *)
public actor CloudKitLibrarySync: CKSyncEngineDelegate {
    private let library: SyncLibrary
    private let store: MinutesStore
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "Library")
    /// Recordings live in their own zone so a device without them never downloads the audio.
    private let recordingsZoneID = CKRecordZone.ID(zoneName: "Recordings")
    private let includesRecordings: Bool
    private var engine: CKSyncEngine?
    /// Payloads in flight (and their temporary files), so an accepted save records exactly what was sent.
    private var sending: [String: (payload: Data, file: URL)] = [:]
    private let onLibraryChanged: @Sendable () -> Void
    private let onStatus: @Sendable (LibrarySyncStatus) -> Void
    private var status = LibrarySyncStatus(phase: .idle, lastSynced: nil, pendingCount: 0)
    private static let log = Logger(subsystem: "app.minutes", category: "Sync")
    private static let stateKey = "cloudkit_sync_engine_state"

    public init(containerIdentifier: String, store: MinutesStore, audioDirectory: URL?,
                onLibraryChanged: @escaping @Sendable () -> Void, onStatus: @escaping @Sendable (LibrarySyncStatus) -> Void) {
        self.store = store
        self.library = SyncLibrary(store: store, audioDirectory: audioDirectory)
        self.includesRecordings = audioDirectory != nil
        self.container = CKContainer(identifier: containerIdentifier)
        self.onLibraryChanged = onLibraryChanged
        self.onStatus = onStatus
    }

    /// Starts the engine (restoring its saved state) and syncs once.
    public func start() async {
        if engine == nil {
            let saved = (try? store.librarySetting(Self.stateKey)).flatMap { Data(base64Encoded: $0) }
                .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            let engine = CKSyncEngine(.init(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self))
            self.engine = engine
            if saved == nil { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID)), .saveZone(CKRecordZone(zoneID: recordingsZoneID))]) }
            // Payload copies from an earlier run hold meeting text; remove them.
            try? FileManager.default.removeItem(at: Self.temporaryDirectory)
        }
        await syncNow()
    }

    /// Queues local edits, then fetches and sends. Safe to call often.
    public func syncNow() async {
        guard let engine else { return }
        publish(.syncing)
        do {
            try queueLocalChanges()
            guard self.engine != nil else { return }
            // Meetings first, so a recording finds its meeting when it arrives.
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            if includesRecordings, self.engine != nil { try await engine.fetchChanges(.init(scope: .zoneIDs([recordingsZoneID]))) }
            guard self.engine != nil else { return }
            try await engine.sendChanges()
            status.lastSynced = Date()
            publish(.idle)
        } catch let error as CKError where error.code == .notAuthenticated {
            publish(.signedOut)
        } catch {
            Self.log.error("Sync failed: \(String(describing: (error as? CKError)?.code ?? .internalError), privacy: .public)")
            publish(.failed(error.localizedDescription))
        }
    }

    /// Stops syncing on this device. Data in iCloud and on other devices stays.
    public func stop() {
        engine = nil
    }

    /// Removes the library from iCloud for every device (the zone), keeping local data.
    public func deleteCloudCopy() async throws {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID), .deleteZone(recordingsZoneID)])
        try await engine.sendChanges()
        try store.resetSyncRecordStates()
        try store.setLibrarySetting(Self.stateKey, value: nil)
        self.engine = nil
    }

    private func queueLocalChanges() throws {
        guard let engine else { return }
        let existing = Set(engine.state.pendingRecordZoneChanges)
        let changes = try library.pendingChanges().map { change -> CKSyncEngine.PendingRecordZoneChange in
            switch change {
            case .save(let name): .saveRecord(recordID(name))
            case .delete(let name): .deleteRecord(recordID(name))
            }
        }.filter { !existing.contains($0) }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
        status.pendingCount = engine.state.pendingRecordZoneChanges.count
    }

    private func recordID(_ name: SyncRecordName) -> CKRecord.ID {
        CKRecord.ID(recordName: name.description, zoneID: name.kind == .audio ? recordingsZoneID : zoneID)
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        includesRecordings ? context.options : .init(scope: .zoneIDs([zoneID]))
    }

    private func publish(_ phase: LibrarySyncStatus.Phase) {
        status.phase = phase
        if let engine { status.pendingCount = engine.state.pendingRecordZoneChanges.count }
        onStatus(status)
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? store.setLibrarySetting(Self.stateKey, value: data.base64EncodedString())
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                try? queueLocalChanges()
            case .signOut, .switchAccounts:
                // Local meetings stay; a different account starts from scratch.
                try? store.resetSyncRecordStates()
                try? store.setLibrarySetting(Self.stateKey, value: nil)
                publish(.signedOut)
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                // The person removed the iCloud copy on another device. Keep local
                // meetings, and stop here rather than uploading everything again.
                try? store.resetSyncRecordStates()
                try? store.setLibrarySetting(Self.stateKey, value: nil)
                engine = nil
                publish(.removedFromICloud)
            }
        case .fetchedRecordZoneChanges(let changes):
            var changed = false
            // Folders and people before the meetings that refer to them.
            let order: [SyncRecordKind] = [.folder, .person, .meeting, .audio]
            let records = changes.modifications.map(\.record).sorted {
                (SyncRecordName($0.recordID.recordName).flatMap { order.firstIndex(of: $0.kind) } ?? 9) <
                (SyncRecordName($1.recordID.recordName).flatMap { order.firstIndex(of: $0.kind) } ?? 9)
            }
            for record in records { changed = apply(record) || changed }
            for deletion in changes.deletions {
                guard let name = SyncRecordName(deletion.recordID.recordName) else { continue }
                changed = ((try? library.applyRemoteDeletion(name)) ?? false) || changed
            }
            if changed { onLibraryChanged() }
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                Self.log.error("Zone save failed: \(String(describing: failure.error.code), privacy: .public)")
            }
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // Small metadata first; recordings last so notes are not held behind them.
        let ordered = pending.sorted { rank($0) < rank($1) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(ordered.prefix(50))) { id in
            await self.record(for: id, engine: syncEngine)
        }
    }

    private func rank(_ change: CKSyncEngine.PendingRecordZoneChange) -> Int {
        let id: CKRecord.ID
        switch change {
        case .saveRecord(let value), .deleteRecord(let value): id = value
        @unknown default: return 4
        }
        switch SyncRecordName(id.recordName)?.kind {
        case .folder: return 0
        case .person: return 1
        case .meeting: return 2
        default: return 3
        }
    }

    /// Builds the CloudKit record to send, or drops the change if the record vanished.
    private func record(for id: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        guard let name = SyncRecordName(id.recordName), let payload = try? library.localPayload(name) else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        let record = (try? library.systemFields(name)).flatMap(Self.unarchive) ?? CKRecord(recordType: name.kind.rawValue, recordID: id)
        do {
            record["payload"] = CKAsset(fileURL: try Self.temporaryFile(payload))
            if name.kind == .audio {
                guard let file = library.audioFile(for: name.id) else { return nil }
                record["audio"] = CKAsset(fileURL: file)
            }
        } catch { return nil }
        record["schema"] = 1 as NSNumber
        if let asset = record["payload"] as? CKAsset, let file = asset.fileURL {
            if let previous = sending[name.description]?.file, previous != file { try? FileManager.default.removeItem(at: previous) }
            sending[name.description] = (payload, file)
        }
        return record
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var changed = false
        for record in sent.savedRecords {
            guard let name = SyncRecordName(record.recordID.recordName), let sent = sending.removeValue(forKey: name.description) else { continue }
            try? FileManager.default.removeItem(at: sent.file)
            try? library.acknowledgeSaved(name, payload: sent.payload, systemFields: Self.archive(record))
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            guard let name = SyncRecordName(id.recordName) else { continue }
            if let sent = sending.removeValue(forKey: name.description) { try? FileManager.default.removeItem(at: sent.file) }
            switch failure.error.code {
            case .serverRecordChanged:
                // Another device saved first: keep its change tag, merge its copy, then send ours again.
                if let server = failure.error.serverRecord {
                    try? library.updateSystemFields(name, Self.archive(server))
                    changed = apply(server) || changed
                }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .unknownItem:
                try? library.clearSystemFields(name)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .quotaExceeded:
                publish(.failed("Your iCloud storage is full. Meetings stay on this device; free space in iCloud to resume sync."))
            default:
                // Network and throttling errors are retried by CKSyncEngine.
                Self.log.error("Record save failed: \(String(describing: failure.error.code), privacy: .public)")
            }
        }
        for id in sent.deletedRecordIDs {
            if let name = SyncRecordName(id.recordName) { try? library.acknowledgeDeleted(name) }
        }
        if changed { onLibraryChanged() }
    }

    /// Applies a fetched or conflicting server record; true when the local library changed.
    private func apply(_ record: CKRecord) -> Bool {
        guard let name = SyncRecordName(record.recordID.recordName),
              let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
              let payload = try? Data(contentsOf: url) else { return false }
        let audio = (record["audio"] as? CKAsset)?.fileURL
        do {
            let result = try library.applyRemote(name, payload: payload, systemFields: Self.archive(record), audioFile: audio)
            if result.needsUpload { engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)]) }
            return result.changedLocalLibrary
        } catch {
            Self.log.error("Could not apply a synced \(name.kind.rawValue, privacy: .public) record")
            return false
        }
    }

    // MARK: Helpers

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func unarchive(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static var temporaryDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("minutes-sync", isDirectory: true) }

    private static func temporaryFile(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
