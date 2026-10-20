import Foundation
import SQLite3

extension MinutesStore {
    /// Runs once for a library, including libraries that already have custom
    /// folders. The durable marker respects later deletion of all starters.
    /// Does not file, rename, or otherwise change any existing meeting.
    @discardableResult
    public func seedStarterFoldersIfNeeded() throws -> Bool {
        var seeded = false
        try withImmediateTransaction {
            let initialized = try folderStatement("SELECT 1 FROM library_settings WHERE key='starter_folders_v1'") { statement in
                let code = sqlite3_step(statement)
                guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read starter folder initialization") }
                return code == SQLITE_ROW
            }
            guard !initialized else { return }
            if try listFolders().isEmpty {
                for (name, description) in [
                    ("Work", "Work projects, team and client meetings, business planning and professional responsibilities."),
                    ("Personal", "Family, friends, home, personal errands, appointments and everyday life."),
                    ("Learning", "Classes, study, research, tutorials, reading and learning new skills.")
                ] {
                    try createFolder(name: name, description: description)
                }
                seeded = true
            }
            try folderWrite("INSERT INTO library_settings(key,value) VALUES ('starter_folders_v1','initialized')")
        }
        return seeded
    }

    /// Small durable library values (for example an exported note's id). Never secrets.
    public func librarySetting(_ key: String) throws -> String? {
        var value: String?
        try withImmediateTransaction {
            value = try folderStatement("SELECT value FROM library_settings WHERE key=?", values: [key]) { statement in
                let code = sqlite3_step(statement)
                guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read library setting") }
                return code == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
            }
        }
        return value
    }

    public func setLibrarySetting(_ key: String, value: String?) throws {
        try withImmediateTransaction {
            if let value { try folderWrite("INSERT INTO library_settings(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", values: [key, value]) }
            else { try folderWrite("DELETE FROM library_settings WHERE key=?", values: [key]) }
        }
    }

    private func folderStatement<T>(_ sql: String, values: [String?] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw databaseError("Prepare folder operation") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        return try body(statement)
    }
    private func folderWrite(_ sql: String, values: [String?] = []) throws {
        try folderStatement(sql, values: values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError("Write folder operation") }
        }
    }
    private func folderExists(id: String) throws -> Bool {
        try folderStatement("SELECT 1 FROM meeting_folder WHERE id=?", values: [id]) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read folder") }
            return code == SQLITE_ROW
        }
    }
    private func meetingExistsForFiling(id: String) throws -> Bool {
        try folderStatement("SELECT 1 FROM meeting WHERE id=?", values: [id]) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read filing meeting") }
            return code == SQLITE_ROW
        }
    }
    private func checkedFolderFields(name: String, description: String) throws -> (String, String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw MeetingFolderError.invalidName }
        guard description.count <= 2_000 else { throw MeetingFolderError.descriptionTooLong }
        return (name, description.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func listFolders() throws -> [MeetingFolder] {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT id,name,description,sort_order,created_at FROM meeting_folder ORDER BY sort_order,created_at,id") { statement in
            var result: [MeetingFolder] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                result.append(MeetingFolder(id: String(cString: sqlite3_column_text(statement, 0)), name: String(cString: sqlite3_column_text(statement, 1)), description: String(cString: sqlite3_column_text(statement, 2)), sortOrder: Int(sqlite3_column_int64(statement, 3)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw databaseError("List folders") }
            return result
        }
    }
    @discardableResult
    public func createFolder(name: String, description: String = "") throws -> MeetingFolder {
        let fields = try checkedFolderFields(name: name, description: description)
        var result: MeetingFolder!
        try withImmediateTransaction {
            let order = try folderStatement("SELECT COALESCE(MAX(sort_order),-1)+1 FROM meeting_folder") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError("Read folder order") }
                return Int(sqlite3_column_int64(statement, 0))
            }
            let folder = MeetingFolder(name: fields.0, description: fields.1, sortOrder: order)
            try folderWrite("INSERT INTO meeting_folder(id,name,description,sort_order,created_at) VALUES (?,?,?,?,?)", values: [folder.id, folder.name, folder.description, String(order), String(folder.createdAt.timeIntervalSince1970)])
            result = folder
        }
        return result
    }
    public func updateFolder(id: String, name: String, description: String) throws {
        let fields = try checkedFolderFields(name: name, description: description)
        try withImmediateTransaction {
            guard try folderExists(id: id) else { throw MeetingFolderError.missingFolder }
            try folderWrite("UPDATE meeting_folder SET name=?,description=? WHERE id=?", values: [fields.0, fields.1, id])
        }
    }
    public func deleteFolder(id: String) throws {
        try withImmediateTransaction {
            guard try folderExists(id: id) else { throw MeetingFolderError.missingFolder }
            // Deleting a folder is an explicit human choice. Its meetings remain
            // Unfiled and protected from an in-flight or subsequent auto move.
            try folderWrite("UPDATE meeting_folder_membership SET folder_id=NULL,source='manual',revision=revision+1 WHERE folder_id=?", values: [id])
            try folderWrite("DELETE FROM meeting_folder WHERE id=?", values: [id])
        }
    }
    public func listFolderMemberships() throws -> [MeetingFolderMembership] {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT meeting_id,folder_id,source,revision FROM meeting_folder_membership ORDER BY meeting_id") { statement in
            var result: [MeetingFolderMembership] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let folder = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 1))
                guard let source = FolderFilingSource(rawValue: String(cString: sqlite3_column_text(statement, 2))) else { throw databaseError("Read filing provenance") }
                result.append(MeetingFolderMembership(meetingID: String(cString: sqlite3_column_text(statement, 0)), folderID: folder, source: source, revision: Int(sqlite3_column_int64(statement, 3))))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw databaseError("List filing provenance") }
            return result
        }
    }
    public func folderMembership(meetingID: String) throws -> MeetingFolderMembership? {
        try listFolderMemberships().first { $0.meetingID == meetingID }
    }
    public func filingRevision(meetingID: String) throws -> Int { try folderMembership(meetingID: meetingID)?.revision ?? 0 }
    public func folderForMeeting(id: String) throws -> MeetingFolder? {
        lock.lock(); defer { lock.unlock() }
        guard let membership = try folderMembership(meetingID: id), let folderID = membership.folderID else { return nil }
        return try listFolders().first { $0.id == folderID }
    }
    public func moveMeeting(id: String, toFolderID: String?) throws {
        try withImmediateTransaction {
            guard try meetingExistsForFiling(id: id) else { throw MeetingFolderError.missingMeeting }
            if let toFolderID, !(try folderExists(id: toFolderID)) { throw MeetingFolderError.missingFolder }
            try folderWrite("""
                INSERT INTO meeting_folder_membership(meeting_id,folder_id,source,revision) VALUES (?,?,'manual',1)
                ON CONFLICT(meeting_id) DO UPDATE SET folder_id=excluded.folder_id,source='manual',revision=revision+1
                """, values: [id, toFolderID])
        }
    }
    /// Atomic across independent connections. A manual Unfiled row is a lock too.
    @discardableResult
    public func applyAutomaticFolder(meetingID: String, folderID: String, expectedRevision: Int) throws -> Bool {
        var changed = false
        try withImmediateTransaction {
            guard try meetingExistsForFiling(id: meetingID), try folderExists(id: folderID) else { return }
            let membership = try folderMembership(meetingID: meetingID)
            guard membership?.source != .manual, (membership?.revision ?? 0) == expectedRevision else { return }
            try folderWrite("""
                INSERT INTO meeting_folder_membership(meeting_id,folder_id,source,revision) VALUES (?,?,'automatic',1)
                ON CONFLICT(meeting_id) DO UPDATE SET folder_id=excluded.folder_id,source='automatic',revision=revision+1
                """, values: [meetingID, folderID])
            changed = true
        }
        return changed
    }
    public func listMeetings(inFolderID: String?) throws -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        let ids: [String] = try folderStatement("""
            SELECT m.id FROM meeting m LEFT JOIN meeting_folder_membership f ON f.meeting_id=m.id
            WHERE f.folder_id IS ? AND m.id NOT IN (SELECT meeting_id FROM meeting_trash) ORDER BY m.started_at DESC,m.id
            """, values: [inFolderID]) { statement in
            var result: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))); code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw databaseError("List folder meetings") }
            return result
        }
        return ids.compactMap { getMeeting(id: $0) }
    }
    public func folderCounts() throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var counts = Dictionary(uniqueKeysWithValues: try listFolders().map { ($0.id, 0) })
        let visible = Set(listMeetings().map(\.id))
        for membership in try listFolderMemberships() where visible.contains(membership.meetingID) { if let id = membership.folderID { counts[id, default: 0] += 1 } }
        return counts
    }
    /// Reversible deletion; never unlinks audio or erases enrolled voice profiles.
    public func trashMeeting(id: String) throws {
        try withImmediateTransaction {
            guard let meeting = getMeeting(id: id) else { throw MeetingFolderError.missingMeeting }
            guard !["starting", "recording", "processing", "transcribing", "diarizing", "summarizing"].contains(meeting.status) else {
                throw NSError(domain: "Minutes.Trash", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish processing or recording before deleting this meeting."])
            }
            try folderWrite("INSERT OR IGNORE INTO meeting_trash(meeting_id,deleted_at) VALUES (?,strftime('%s','now'))", values: [id])
        }
    }
    public func restoreMeeting(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try folderWrite("DELETE FROM meeting_trash WHERE meeting_id=?", values: [id])
    }

    public func unfiledMeetingCount() throws -> Int { try listMeetings(inFolderID: nil).count }
}

public final class MinutesStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    
    public init(dbPath: String) throws {
        let dir = (dbPath as NSString).deletingLastPathComponent
        if !dir.isEmpty { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        
        var handle: OpaquePointer?
        if sqlite3_open(dbPath, &handle) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "MinutesStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open db failed: \(msg)"])
        }
        self.db = handle
        try migrate()
        if dbPath != ":memory:" {
            try relocateManagedAudioPaths(to: URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("audio", isDirectory: true))
        }
    }
    
    /// iOS may change the sandbox UUID during an update or restore. Repair
    /// database references only; never move, rewrite, or delete recording bytes.
    /// External files and missing managed files are deliberately left untouched.
    public func relocateManagedAudioPaths(to directory: URL) throws {
        try withImmediateTransaction {
            for var meeting in listMeetings() + listMeetings(inTrash: true) {
                guard let path = meeting.audioPath,
                      !FileManager.default.fileExists(atPath: path),
                      let marker = path.range(of: "/Library/Application Support/Minutes/audio/", options: .backwards) else { continue }
                let filename = String(path[marker.upperBound...])
                guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else { continue }
                let candidate = directory.appendingPathComponent(filename)
                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                meeting.audioPath = candidate.path
                try saveMeeting(meeting)
            }
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func databaseError(_ operation: String) -> NSError {
        NSError(domain: "MinutesStore", code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: sqlite3_errmsg(db)))"])
    }

    // Call only while holding the store lock. Savepoints make batches atomic,
    // including when called from a larger application transaction.
    private func atomicWrite(_ body: () throws -> Void) throws {
        guard sqlite3_exec(db, "SAVEPOINT minutes_batch", nil, nil, nil) == SQLITE_OK else {
            throw databaseError("Begin write")
        }
        do {
            try body()
            guard sqlite3_exec(db, "RELEASE minutes_batch", nil, nil, nil) == SQLITE_OK else {
                throw databaseError("Commit write")
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK TO minutes_batch", nil, nil, nil)
            sqlite3_exec(db, "RELEASE minutes_batch", nil, nil, nil)
            throw error
        }
    }

    /// Serializes read/decide/write queue operations across independent SQLite connections.
    public func withImmediateTransaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if !ownsTransaction { try body(); return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError("Begin queue transaction") }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        try body()
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError("Commit queue transaction") }
        committed = true
    }

    public func withTransaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try atomicWrite(body)
    }

    public func replaceMeetingAttendees(meetingId: String, attendees: [MeetingAttendee]) throws {
        guard attendees.allSatisfy({ $0.meetingId == meetingId }) else {
            throw NSError(domain: "MinutesStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Attendee belongs to a different meeting"])
        }
        try withTransaction {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM meeting_attendee WHERE meeting_id = ?", -1, &stmt, nil) == SQLITE_OK else {
                throw databaseError("Prepare replace attendees")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Replace attendees") }
            try saveMeetingAttendees(attendees)
        }
    }

    public func currentSchemaVersion() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        return 0
    }
    
    public func setSchemaVersion(_ version: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let sql = "PRAGMA user_version = \(version);"
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown error"
            sqlite3_free(err)
            throw NSError(domain: "MinutesStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Set version failed: \(msg)"])
        }
    }
    
    public func migrate() throws {
        let pragmas = """
        PRAGMA busy_timeout = 5000;
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        """
        
        let schemaV1 = """
        CREATE TABLE IF NOT EXISTS person (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            is_me INTEGER DEFAULT 0,
            emails_json TEXT NOT NULL DEFAULT '[]',
            parachute_note_id TEXT
        );
        CREATE TABLE IF NOT EXISTS voiceprint (
            id TEXT PRIMARY KEY,
            person_id TEXT NOT NULL,
            model TEXT NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL,
            speech_seconds REAL NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(person_id) REFERENCES person(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS meeting (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            platform TEXT NOT NULL,
            calendar_event_id TEXT,
            conference_url TEXT,
            status TEXT NOT NULL,
            device TEXT,
            user_notes TEXT,
            audio_path TEXT
        );
        CREATE TABLE IF NOT EXISTS meeting_attendee (
            meeting_id TEXT NOT NULL,
            person_id TEXT,
            email TEXT NOT NULL,
            name TEXT,
            is_organizer INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(meeting_id, email),
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS speaker_cluster (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            label TEXT NOT NULL,
            centroid BLOB,
            speech_seconds REAL NOT NULL DEFAULT 0.0,
            person_id TEXT,
            assignment TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.0,
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS utterance (
            id INTEGER NOT NULL,
            meeting_id TEXT NOT NULL,
            cluster_id TEXT NOT NULL,
            speaker_name TEXT NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            text TEXT NOT NULL,
            words_json TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY(meeting_id, id),
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS summary (
            meeting_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            overview TEXT NOT NULL,
            decisions_json TEXT NOT NULL,
            action_items_json TEXT NOT NULL,
            topics_json TEXT NOT NULL,
            questions_json TEXT NOT NULL,
            markdown TEXT NOT NULL,
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS bookmark (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            label TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS outbox_item (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            destination_vault TEXT NOT NULL,
            source_revision INTEGER NOT NULL,
            idempotency_key TEXT NOT NULL,
            status TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            last_attempt_at REAL,
            receipt_json TEXT,
            error_message TEXT,
            payload_json TEXT NOT NULL,
            FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
        );
        """
        
        lock.lock()
        defer { lock.unlock() }
        
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, pragmas, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown error"
            sqlite3_free(err)
            throw NSError(domain: "MinutesStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pragma setup failed: \(msg)"])
        }
        
        if sqlite3_exec(db, schemaV1, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown error"
            sqlite3_free(err)
            throw NSError(domain: "MinutesStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Migration failed: \(msg)"])
        }
        
        // Safe migration for utterance composite primary key if upgrading from legacy schema
        var tableInfoStmt: OpaquePointer?
        var hasUtterance = false
        var isCompositePK = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(utterance);", -1, &tableInfoStmt, nil) == SQLITE_OK {
            while sqlite3_step(tableInfoStmt) == SQLITE_ROW {
                hasUtterance = true
                if let nameCol = sqlite3_column_text(tableInfoStmt, 1) {
                    let col = String(cString: nameCol)
                    let isPk = sqlite3_column_int(tableInfoStmt, 5) > 0
                    if col == "meeting_id" && isPk {
                        isCompositePK = true
                    }
                }
            }
            sqlite3_finalize(tableInfoStmt)
        }
        
        if hasUtterance && !isCompositePK {
            let migrateUtteranceSQL = """
            CREATE TABLE utterance_v2 (
                id INTEGER NOT NULL,
                meeting_id TEXT NOT NULL,
                cluster_id TEXT NOT NULL,
                speaker_name TEXT NOT NULL,
                start REAL NOT NULL,
                end REAL NOT NULL,
                text TEXT NOT NULL,
                words_json TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY(meeting_id, id),
                FOREIGN KEY(meeting_id) REFERENCES meeting(id) ON DELETE CASCADE
            );
            INSERT OR IGNORE INTO utterance_v2 (id, meeting_id, cluster_id, speaker_name, start, end, text, words_json)
                SELECT id, meeting_id, cluster_id, speaker_name, start, end, text, words_json FROM utterance;
            DROP TABLE utterance;
            ALTER TABLE utterance_v2 RENAME TO utterance;
            """
            _ = sqlite3_exec(db, migrateUtteranceSQL, nil, nil, nil)
        }
        
        // Safe migration for meeting audio_path if upgrading from legacy schema
        var meetingInfoStmt: OpaquePointer?
        var hasAudioPath = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(meeting);", -1, &meetingInfoStmt, nil) == SQLITE_OK {
            while sqlite3_step(meetingInfoStmt) == SQLITE_ROW {
                if let nameCol = sqlite3_column_text(meetingInfoStmt, 1) {
                    if String(cString: nameCol) == "audio_path" {
                        hasAudioPath = true
                    }
                }
            }
            sqlite3_finalize(meetingInfoStmt)
        }
        if !hasAudioPath {
            _ = sqlite3_exec(db, "ALTER TABLE meeting ADD COLUMN audio_path TEXT;", nil, nil, nil)
        }
        
        // v3_cluster_embedding_provenance: additive migration; legacy vectors stay untagged.
        var provenanceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(speaker_cluster);", -1, &provenanceStmt, nil) == SQLITE_OK else {throw databaseError("Read cluster schema")}
        var hasProvenance = false
        while sqlite3_step(provenanceStmt) == SQLITE_ROW {
            if let col=sqlite3_column_text(provenanceStmt,1), String(cString:col)=="embedding_model" {hasProvenance=true}
        }
        sqlite3_finalize(provenanceStmt)
        if !hasProvenance && sqlite3_exec(db,"ALTER TABLE speaker_cluster ADD COLUMN embedding_model TEXT;",nil,nil,nil) != SQLITE_OK {throw databaseError("Add embedding provenance")}

        // v4_outbox_origin: legacy rows remain unbound and cannot be sent by a native connection.
        var originStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(outbox_item);", -1, &originStmt, nil) == SQLITE_OK else { throw databaseError("Read outbox schema") }
        var hasOrigin = false
        while sqlite3_step(originStmt) == SQLITE_ROW {
            if let col = sqlite3_column_text(originStmt, 1), String(cString: col) == "destination_origin" { hasOrigin = true }
        }
        sqlite3_finalize(originStmt)
        if !hasOrigin && sqlite3_exec(db, "ALTER TABLE outbox_item ADD COLUMN destination_origin TEXT;", nil, nil, nil) != SQLITE_OK { throw databaseError("Bind outbox origin") }

        // v5_outbox_grant_revision: opaque grant binding and actual committed server precondition.
        for (column, type) in [("grant_fingerprint", "TEXT"), ("base_server_revision", "INTEGER")] {
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(outbox_item);", -1, &schema, nil) == SQLITE_OK else { throw databaseError("Read outbox grant schema") }
            var exists = false
            while sqlite3_step(schema) == SQLITE_ROW {
                if let name = sqlite3_column_text(schema, 1), String(cString: name) == column { exists = true }
            }
            sqlite3_finalize(schema)
            if !exists && sqlite3_exec(db, "ALTER TABLE outbox_item ADD COLUMN \(column) \(type);", nil, nil, nil) != SQLITE_OK { throw databaseError("Add outbox grant precondition") }
        }

        // v6_meeting_folders: additive tables; no changes to meeting/export payloads.
        let folderSchema = """
        CREATE TABLE IF NOT EXISTS meeting_folder (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
            sort_order INTEGER NOT NULL, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meeting_folder_membership (
            meeting_id TEXT PRIMARY KEY REFERENCES meeting(id) ON DELETE CASCADE,
            folder_id TEXT REFERENCES meeting_folder(id) ON DELETE SET NULL,
            source TEXT NOT NULL CHECK(source IN ('manual','automatic')),
            revision INTEGER NOT NULL CHECK(revision > 0)
        );
        CREATE INDEX IF NOT EXISTS meeting_folder_membership_folder ON meeting_folder_membership(folder_id);
        """
        guard sqlite3_exec(db, folderSchema, nil, nil, nil) == SQLITE_OK else { throw databaseError("Add meeting folders") }

        // v7_library_settings: durable one-time initialization, separate from
        // shipped v6 folder tables. User deletion must not recreate defaults.
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS library_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw databaseError("Add library settings") }

        // v8_invitation_response: retain RSVP independently of speaker assignments.
        var responseColumnFound = false
        var responseStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(meeting_attendee)", -1, &responseStmt, nil) == SQLITE_OK {
            while sqlite3_step(responseStmt) == SQLITE_ROW {
                if String(cString: sqlite3_column_text(responseStmt, 1)) == "response_status" { responseColumnFound = true }
            }
        }
        sqlite3_finalize(responseStmt)
        if !responseColumnFound {
            guard sqlite3_exec(db, "ALTER TABLE meeting_attendee ADD COLUMN response_status TEXT NOT NULL DEFAULT 'unknown'", nil, nil, nil) == SQLITE_OK else { throw databaseError("Add invitation response") }
        }

        // v9_meeting_trash: reversible deletion preserves audio and all child records.
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meeting_trash (meeting_id TEXT PRIMARY KEY REFERENCES meeting(id) ON DELETE CASCADE, deleted_at REAL NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw databaseError("Add meeting trash") }

        // v10_sync_record: the last copy exchanged with the person's private iCloud
        // database per record (3-way merge base) plus CloudKit's opaque system fields.
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS sync_record (record_name TEXT PRIMARY KEY, base_payload BLOB, system_fields BLOB);", nil, nil, nil) == SQLITE_OK else { throw databaseError("Add sync records") }

        // v11_sync_dirty: triggers mark the synced record a row belongs to whenever it
        // changes (app or CLI), so a sync pass only re-encodes what changed.
        let syncDirtyExisted = try folderStatement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_dirty'") { sqlite3_step($0) == SQLITE_ROW }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS sync_dirty (record_name TEXT PRIMARY KEY);", nil, nil, nil) == SQLITE_OK else { throw databaseError("Add sync change marks") }
        let syncTriggers: [(table: String, records: [String])] = [
            ("meeting", ["'Meeting:'||ROW.id", "'Audio:'||ROW.id"]),
            ("utterance", ["'Meeting:'||ROW.meeting_id"]), ("summary", ["'Meeting:'||ROW.meeting_id"]),
            ("bookmark", ["'Meeting:'||ROW.meeting_id"]), ("speaker_cluster", ["'Meeting:'||ROW.meeting_id"]),
            ("meeting_attendee", ["'Meeting:'||ROW.meeting_id"]), ("meeting_trash", ["'Meeting:'||ROW.meeting_id"]),
            ("meeting_folder_membership", ["'Meeting:'||ROW.meeting_id"]),
            ("meeting_folder", ["'Folder:'||ROW.id"]), ("person", ["'Person:'||ROW.id"]),
        ]
        for (table, records) in syncTriggers {
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                // An outer upsert's conflict policy overrides OR IGNORE inside a trigger, so test first.
                let inserts = records.map { record -> String in
                    let value = record.replacingOccurrences(of: "ROW", with: row)
                    return "INSERT INTO sync_dirty(record_name) SELECT \(value) WHERE NOT EXISTS (SELECT 1 FROM sync_dirty WHERE record_name = \(value));"
                }.joined(separator: " ")
                let sql = "CREATE TRIGGER IF NOT EXISTS sync_dirty_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN \(inserts) END;"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError("Add sync change trigger") }
            }
        }
        if !syncDirtyExisted {
            // Everything that existed before tracking began is new to sync.
            let seed = """
            INSERT OR IGNORE INTO sync_dirty SELECT 'Meeting:'||id FROM meeting;
            INSERT OR IGNORE INTO sync_dirty SELECT 'Audio:'||id FROM meeting;
            INSERT OR IGNORE INTO sync_dirty SELECT 'Folder:'||id FROM meeting_folder;
            INSERT OR IGNORE INTO sync_dirty SELECT 'Person:'||id FROM person;
            """
            guard sqlite3_exec(db, seed, nil, nil, nil) == SQLITE_OK else { throw databaseError("Seed sync change marks") }
        }

        // Upgrade user_version to at least 1 if not set
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &vStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(vStmt) }
            if sqlite3_step(vStmt) == SQLITE_ROW {
                let currentVer = sqlite3_column_int(vStmt, 0)
                if currentVer < 1 {
                    _ = sqlite3_exec(db, "PRAGMA user_version = 1;", nil, nil, nil)
                }
            }
        }
    }
    
    // MARK: - Meetings
    
    /// `saveMeeting` never clears a path (COALESCE guards partial updates);
    /// deleting a meeting's audio is the one intentional way to do so.
    public func clearAudioPath(meetingId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE meeting SET audio_path = NULL WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Clear audio path") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Clear audio path") }
    }

    public func saveMeeting(_ m: Meeting) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO meeting (id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes, audio_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            ended_at = excluded.ended_at,
            status = excluded.status,
            user_notes = excluded.user_notes,
            calendar_event_id = COALESCE(excluded.calendar_event_id, meeting.calendar_event_id),
            conference_url = COALESCE(excluded.conference_url, meeting.conference_url),
            device = COALESCE(excluded.device, meeting.device),
            audio_path = COALESCE(excluded.audio_path, meeting.audio_path);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (m.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (m.title as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, m.startedAt.timeIntervalSince1970)
            if let ended = m.endedAt {
                sqlite3_bind_double(stmt, 4, ended.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (m.platform as NSString).utf8String, -1, nil)
            if let cal = m.calendarEventId { sqlite3_bind_text(stmt, 6, (cal as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 6) }
            if let conf = m.conferenceURL { sqlite3_bind_text(stmt, 7, (conf as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, (m.status as NSString).utf8String, -1, nil)
            if let dev = m.device { sqlite3_bind_text(stmt, 9, (dev as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 9) }
            if let notes = m.userNotes { sqlite3_bind_text(stmt, 10, (notes as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 10) }
            if let aPath = m.audioPath { sqlite3_bind_text(stmt, 11, (aPath as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 11) }
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Save meeting error: \(msg)"])
            }
        }
    }
    
    public func getMeeting(id: String) -> Meeting? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes, audio_path FROM meeting WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let mId = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                var ended: Date? = nil
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    ended = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                }
                let platform = String(cString: sqlite3_column_text(stmt, 4))
                var cal: String? = nil
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                    cal = String(cString: sqlite3_column_text(stmt, 5))
                }
                var conf: String? = nil
                if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                    conf = String(cString: sqlite3_column_text(stmt, 6))
                }
                let status = String(cString: sqlite3_column_text(stmt, 7))
                var dev: String? = nil
                if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                    dev = String(cString: sqlite3_column_text(stmt, 8))
                }
                var notes: String? = nil
                if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                    notes = String(cString: sqlite3_column_text(stmt, 9))
                }
                var audioPath: String? = nil
                if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                    audioPath = String(cString: sqlite3_column_text(stmt, 10))
                }
                return Meeting(id: mId, title: title, startedAt: started, endedAt: ended, platform: platform, calendarEventId: cal, conferenceURL: conf, status: status, device: dev, userNotes: notes, audioPath: audioPath)
            }
        }
        return nil
    }
    
    /// Latest local meetings linked by person ID, never by a matching display name.
    /// Attendance and speaker evidence remain separate; suggested links need review.
    /// Pass `.max` for the person's full history.
    public func listMeetings(forPersonId personId: String, limit: Int = 100) throws -> [PersonMeetingHistoryEntry] {
        guard limit > 0, !personId.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT m.id, m.title, m.started_at, m.ended_at, m.platform,
               m.calendar_event_id, m.conference_url, m.status, m.device, m.user_notes, m.audio_path,
               EXISTS(SELECT 1 FROM meeting_attendee a WHERE a.meeting_id = m.id AND a.person_id = ?1),
               EXISTS(SELECT 1 FROM speaker_cluster c WHERE c.meeting_id = m.id AND c.person_id = ?1 AND c.assignment = 'user'),
               EXISTS(SELECT 1 FROM speaker_cluster c WHERE c.meeting_id = m.id AND c.person_id = ?1 AND c.assignment = 'auto'),
               EXISTS(SELECT 1 FROM speaker_cluster c WHERE c.meeting_id = m.id AND c.person_id = ?1)
        FROM meeting m
        WHERE m.id NOT IN (SELECT meeting_id FROM meeting_trash)
          AND (EXISTS(SELECT 1 FROM meeting_attendee a WHERE a.meeting_id = m.id AND a.person_id = ?1)
           OR EXISTS(SELECT 1 FROM speaker_cluster c WHERE c.meeting_id = m.id AND c.person_id = ?1))
        ORDER BY m.started_at DESC, m.id ASC
        LIMIT ?2
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Prepare person meeting history") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (personId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(min(limit, Int(Int64.max))))
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(stmt, column) != SQLITE_NULL, let value = sqlite3_column_text(stmt, column) else { return nil }
            return String(cString: value)
        }
        var history: [PersonMeetingHistoryEntry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw databaseError("Read person meeting history") }
            guard let id = text(0), let title = text(1), let platform = text(4), let status = text(7) else {
                throw NSError(domain: "MinutesStore", code: Int(SQLITE_CORRUPT), userInfo: [NSLocalizedDescriptionKey: "Person history contains incomplete meeting metadata."])
            }
            let meeting = Meeting(id: id, title: title,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                platform: platform, calendarEventId: text(5), conferenceURL: text(6), status: status,
                device: text(8), userNotes: text(9), audioPath: text(10))
            history.append(PersonMeetingHistoryEntry(meeting: meeting,
                calendarInvitee: sqlite3_column_int(stmt, 11) != 0,
                confirmedSpeaker: sqlite3_column_int(stmt, 12) != 0,
                recognizedSpeaker: sqlite3_column_int(stmt, 13) != 0,
                speakerLinked: sqlite3_column_int(stmt, 14) != 0))
        }
        return history
    }

    public func listMeetings(inTrash: Bool = false) -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Meeting] = []
        let sql = "SELECT id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes, audio_path FROM meeting WHERE id \(inTrash ? "IN" : "NOT IN") (SELECT meeting_id FROM meeting_trash) ORDER BY started_at DESC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let mId = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                var ended: Date? = nil
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    ended = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                }
                let platform = String(cString: sqlite3_column_text(stmt, 4))
                var cal: String? = nil
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                    cal = String(cString: sqlite3_column_text(stmt, 5))
                }
                var conf: String? = nil
                if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                    conf = String(cString: sqlite3_column_text(stmt, 6))
                }
                let status = String(cString: sqlite3_column_text(stmt, 7))
                var dev: String? = nil
                if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                    dev = String(cString: sqlite3_column_text(stmt, 8))
                }
                var notes: String? = nil
                if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                    notes = String(cString: sqlite3_column_text(stmt, 9))
                }
                var audioPath: String? = nil
                if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                    audioPath = String(cString: sqlite3_column_text(stmt, 10))
                }
                list.append(Meeting(id: mId, title: title, startedAt: started, endedAt: ended, platform: platform, calendarEventId: cal, conferenceURL: conf, status: status, device: dev, userNotes: notes, audioPath: audioPath))
            }
        }
        return list
    }
    
    /// Call once when a new app process starts, never during a live capture refresh.
    /// Preserve paths, timestamps and bytes; an interrupted file is not certified audio.
    public func markAbandonedRecordingsInterrupted() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, "UPDATE meeting SET status = 'interrupted' WHERE status IN ('starting', 'recording')", nil, nil, nil) == SQLITE_OK else {
            throw databaseError("Recover interrupted recordings")
        }
        return Int(sqlite3_changes(db))
    }

    public func deleteMeeting(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "DELETE FROM meeting WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 6, userInfo: [NSLocalizedDescriptionKey: "Delete meeting error: \(msg)"])
            }
        }
    }
    
    // MARK: - Person & Voiceprints
    
    public func savePerson(_ p: Person) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO person (id, display_name, is_me, emails_json, parachute_note_id)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            display_name = excluded.display_name,
            is_me = excluded.is_me,
            emails_json = excluded.emails_json,
            parachute_note_id = excluded.parachute_note_id;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            let emailsData = (try? JSONEncoder().encode(p.emails)) ?? Data("[]".utf8)
            let emailsStr = String(data: emailsData, encoding: .utf8) ?? "[]"
            
            sqlite3_bind_text(stmt, 1, (p.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (p.displayName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, p.isMe ? 1 : 0)
            sqlite3_bind_text(stmt, 4, (emailsStr as NSString).utf8String, -1, nil)
            if let noteId = p.parachuteNoteId { sqlite3_bind_text(stmt, 5, (noteId as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 5) }
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Save person error: \(msg)"])
            }
        }
    }
    
    public func listPeople() -> [Person] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Person] = []
        let sql = "SELECT id, display_name, is_me, emails_json, parachute_note_id FROM person"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let isMe = sqlite3_column_int(stmt, 2) == 1
                let emailsStr = String(cString: sqlite3_column_text(stmt, 3))
                let emails = (try? JSONDecoder().decode([String].self, from: Data(emailsStr.utf8))) ?? []
                var noteId: String? = nil
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    noteId = String(cString: sqlite3_column_text(stmt, 4))
                }
                list.append(Person(id: id, displayName: name, isMe: isMe, emails: emails, parachuteNoteId: noteId))
            }
        }
        return list
    }
    
    public func getPerson(id: String) -> Person? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT id, display_name, is_me, emails_json, parachute_note_id FROM person WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let pId = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let isMe = sqlite3_column_int(stmt, 2) == 1
                let emailsStr = String(cString: sqlite3_column_text(stmt, 3))
                let emails = (try? JSONDecoder().decode([String].self, from: Data(emailsStr.utf8))) ?? []
                var noteId: String? = nil
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    noteId = String(cString: sqlite3_column_text(stmt, 4))
                }
                return Person(id: pId, displayName: name, isMe: isMe, emails: emails, parachuteNoteId: noteId)
            }
        }
        return nil
    }

    public func saveMeetingAttendees(_ attendees: [MeetingAttendee]) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO meeting_attendee (meeting_id, person_id, email, name, is_organizer, response_status)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(meeting_id, email) DO UPDATE SET
            person_id = excluded.person_id,
            name = excluded.name,
            is_organizer = excluded.is_organizer,
            response_status = excluded.response_status;
        """
        try atomicWrite {
        for a in attendees {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (a.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if let pid = a.personId { sqlite3_bind_text(stmt, 2, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
                sqlite3_bind_text(stmt, 3, (a.email as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if let name = a.name { sqlite3_bind_text(stmt, 4, (name as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
                sqlite3_bind_int(stmt, 5, a.isOrganizer ? 1 : 0)
                sqlite3_bind_text(stmt, 6, (a.responseStatus as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Write saveMeetingAttendees") }
            } else {
                throw databaseError("Prepare saveMeetingAttendees")
            }
        }
        }
    }

    public func listMeetingAttendees(meetingId: String) -> [MeetingAttendee] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [MeetingAttendee] = []
        let sql = "SELECT meeting_id, person_id, email, name, is_organizer, response_status FROM meeting_attendee WHERE meeting_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let mId = String(cString: sqlite3_column_text(stmt, 0))
                var pId: String? = nil
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL { pId = String(cString: sqlite3_column_text(stmt, 1)) }
                let email = String(cString: sqlite3_column_text(stmt, 2))
                var name: String? = nil
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL { name = String(cString: sqlite3_column_text(stmt, 3)) }
                let isOrg = sqlite3_column_int(stmt, 4) == 1
                let response = String(cString: sqlite3_column_text(stmt, 5))
                list.append(MeetingAttendee(meetingId: mId, personId: pId, email: email, name: name, isOrganizer: isOrg, responseStatus: response))
            }
        }
        return list
    }

    public func listPeopleForMeeting(meetingId: String) -> [Person] {
        let attendees = listMeetingAttendees(meetingId: meetingId)
        let clusters = listSpeakerClusters(meetingId: meetingId)
        
        var personIds = Set<String>()
        for a in attendees {
            if let pid = a.personId { personIds.insert(pid) }
        }
        for c in clusters {
            if let pid = c.personId { personIds.insert(pid) }
        }
        
        var people: [Person] = []
        for pid in personIds {
            if let p = getPerson(id: pid) {
                people.append(p)
            }
        }
        return people
    }
    
    public func saveVoiceprint(_ vp: Voiceprint) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO voiceprint (id, person_id, model, dim, vector, speech_seconds, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (vp.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (vp.personId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (vp.model as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(vp.dim))
            
            // Pack Float array to byte buffer
            let byteCount = vp.vector.count * MemoryLayout<Float>.size
            _ = vp.vector.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(byteCount), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(stmt, 6, vp.speechSeconds)
            sqlite3_bind_double(stmt, 7, vp.createdAt.timeIntervalSince1970)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "Save voiceprint error: \(msg)"])
            }
        }
    }
    
    public func listVoiceprints() -> [Voiceprint] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Voiceprint] = []
        let sql = "SELECT id, person_id, model, dim, vector, speech_seconds, created_at FROM voiceprint"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let personId = String(cString: sqlite3_column_text(stmt, 1))
                let model = String(cString: sqlite3_column_text(stmt, 2))
                let dim = Int(sqlite3_column_int(stmt, 3))
                
                let blob = sqlite3_column_blob(stmt, 4)
                let bytes = sqlite3_column_bytes(stmt, 4)
                var vector: [Float] = []
                if let blob = blob, bytes > 0 {
                    let floatCount = Int(bytes) / MemoryLayout<Float>.size
                    let floatBuffer = blob.bindMemory(to: Float.self, capacity: floatCount)
                    vector = Array(UnsafeBufferPointer(start: floatBuffer, count: floatCount))
                }
                
                let speechSeconds = sqlite3_column_double(stmt, 5)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                list.append(Voiceprint(id: id, personId: personId, model: model, dim: dim, vector: vector, speechSeconds: speechSeconds, createdAt: createdAt))
            }
        }
        return list
    }
    
    public func getVoiceprint(id: String) -> Voiceprint? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT id, person_id, model, dim, vector, speech_seconds, created_at FROM voiceprint WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let vId = String(cString: sqlite3_column_text(stmt, 0))
                let personId = String(cString: sqlite3_column_text(stmt, 1))
                let model = String(cString: sqlite3_column_text(stmt, 2))
                let dim = Int(sqlite3_column_int(stmt, 3))
                
                let blob = sqlite3_column_blob(stmt, 4)
                let bytes = sqlite3_column_bytes(stmt, 4)
                var vector: [Float] = []
                if let blob = blob, bytes > 0 {
                    let floatCount = Int(bytes) / MemoryLayout<Float>.size
                    let floatBuffer = blob.bindMemory(to: Float.self, capacity: floatCount)
                    vector = Array(UnsafeBufferPointer(start: floatBuffer, count: floatCount))
                }
                
                let speechSeconds = sqlite3_column_double(stmt, 5)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                return Voiceprint(id: vId, personId: personId, model: model, dim: dim, vector: vector, speechSeconds: speechSeconds, createdAt: createdAt)
            }
        }
        return nil
    }
    
    public func deleteVoiceprint(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "DELETE FROM voiceprint WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 7, userInfo: [NSLocalizedDescriptionKey: "Delete voiceprint error: \(msg)"])
            }
        }
    }
    
    public func deleteSpeakerCluster(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "DELETE FROM speaker_cluster WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 8, userInfo: [NSLocalizedDescriptionKey: "Delete cluster error: \(msg)"])
            }
        }
    }
    
    // MARK: - Speaker Clusters & Utterances
    
    public func saveSpeakerClusters(_ clusters: [SpeakerCluster]) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO speaker_cluster (id, meeting_id, track_id, label, centroid, speech_seconds, person_id, assignment, confidence, embedding_model)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            meeting_id = excluded.meeting_id,
            track_id = excluded.track_id,
            label = excluded.label,
            centroid = excluded.centroid,
            speech_seconds = excluded.speech_seconds,
            person_id = excluded.person_id,
            assignment = excluded.assignment,
            confidence = excluded.confidence,
            embedding_model = excluded.embedding_model;
        """
        try atomicWrite {
        for c in clusters {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (c.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (c.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (c.trackId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (c.label as NSString).utf8String, -1, SQLITE_TRANSIENT)
                
                let byteCount = c.centroid.count * MemoryLayout<Float>.size
                if byteCount > 0 {
                    _ = c.centroid.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(byteCount), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                
                sqlite3_bind_double(stmt, 6, c.speechSeconds)
                if let pid = c.personId { sqlite3_bind_text(stmt, 7, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
                sqlite3_bind_text(stmt, 8, (c.assignment as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 9, c.confidence)
                if let model=c.embeddingModel {sqlite3_bind_text(stmt,10,(model as NSString).utf8String,-1,SQLITE_TRANSIENT)} else {sqlite3_bind_null(stmt,10)}
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Write saveSpeakerClusters") }
            } else {
                throw databaseError("Prepare saveSpeakerClusters")
            }
        }
        }
    }
    
    public func listSpeakerClusters(meetingId: String) -> [SpeakerCluster] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [SpeakerCluster] = []
        let sql = "SELECT id, meeting_id, track_id, label, centroid, speech_seconds, person_id, assignment, confidence, embedding_model FROM speaker_cluster WHERE meeting_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let mId = String(cString: sqlite3_column_text(stmt, 1))
                let tId = String(cString: sqlite3_column_text(stmt, 2))
                let label = String(cString: sqlite3_column_text(stmt, 3))
                
                var centroid: [Float] = []
                if let blob = sqlite3_column_blob(stmt, 4) {
                    let bytes = sqlite3_column_bytes(stmt, 4)
                    let count = Int(bytes) / MemoryLayout<Float>.size
                    let ptr = blob.bindMemory(to: Float.self, capacity: count)
                    centroid = Array(UnsafeBufferPointer(start: ptr, count: count))
                }
                let speechSeconds = sqlite3_column_double(stmt, 5)
                var personId: String? = nil
                if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                    personId = String(cString: sqlite3_column_text(stmt, 6))
                }
                let assignment = String(cString: sqlite3_column_text(stmt, 7))
                let confidence = sqlite3_column_double(stmt, 8)
                list.append(SpeakerCluster(id: id, meetingId: mId, trackId: tId, label: label, centroid: centroid, speechSeconds: speechSeconds, personId: personId, assignment: assignment, confidence: confidence, embeddingModel: sqlite3_column_type(stmt,9)==SQLITE_NULL ? nil : String(cString:sqlite3_column_text(stmt,9))))
            }
        }
        return list
    }
    
    public func saveUtterances(_ utterances: [Utterance]) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO utterance (id, meeting_id, cluster_id, speaker_name, start, end, text, words_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(meeting_id, id) DO UPDATE SET
            cluster_id = excluded.cluster_id,
            speaker_name = excluded.speaker_name,
            start = excluded.start,
            end = excluded.end,
            text = excluded.text,
            words_json = excluded.words_json;
        """
        try atomicWrite {
        for u in utterances {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                let wordsData = try JSONEncoder().encode(u.words)
                let wordsStr = String(data: wordsData, encoding: .utf8) ?? "[]"
                
                sqlite3_bind_int(stmt, 1, Int32(u.id))
                sqlite3_bind_text(stmt, 2, (u.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (u.clusterId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (u.speakerName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 5, u.start)
                sqlite3_bind_double(stmt, 6, u.end)
                sqlite3_bind_text(stmt, 7, (u.text as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, (wordsStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Write saveUtterances") }
            } else {
                throw databaseError("Prepare saveUtterances")
            }
        }
        }
    }
    
    public func listUtterances(meetingId: String) -> [Utterance] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Utterance] = []
        let sql = "SELECT id, meeting_id, cluster_id, speaker_name, start, end, text, words_json FROM utterance WHERE meeting_id = ? ORDER BY start ASC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let mId = String(cString: sqlite3_column_text(stmt, 1))
                let clusterId = String(cString: sqlite3_column_text(stmt, 2))
                let speaker = String(cString: sqlite3_column_text(stmt, 3))
                let start = sqlite3_column_double(stmt, 4)
                let end = sqlite3_column_double(stmt, 5)
                let text = String(cString: sqlite3_column_text(stmt, 6))
                let wordsStr = String(cString: sqlite3_column_text(stmt, 7))
                let words = (try? JSONDecoder().decode([WordTiming].self, from: Data(wordsStr.utf8))) ?? []
                list.append(Utterance(id: id, meetingId: mId, clusterId: clusterId, speakerName: speaker, start: start, end: end, text: text, words: words))
            }
        }
        return list
    }
    
    // MARK: - Summary
    
    public func saveSummary(_ s: MeetingSummary) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO summary (meeting_id, title, overview, decisions_json, action_items_json, topics_json, questions_json, markdown)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(meeting_id) DO UPDATE SET
            title = excluded.title,
            overview = excluded.overview,
            decisions_json = excluded.decisions_json,
            action_items_json = excluded.action_items_json,
            topics_json = excluded.topics_json,
            questions_json = excluded.questions_json,
            markdown = excluded.markdown;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            let decStr = String(data: (try? JSONEncoder().encode(s.decisions)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            let actStr = String(data: (try? JSONEncoder().encode(s.actionItems)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            let topStr = String(data: (try? JSONEncoder().encode(s.topics)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            let queStr = String(data: (try? JSONEncoder().encode(s.questions)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            
            sqlite3_bind_text(stmt, 1, (s.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (s.title as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (s.overview as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (decStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, (actStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, (topStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, (queStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, (s.markdown as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Write summary") }
        } else {
            throw databaseError("Prepare summary")
        }
    }
    
    public func getSummary(meetingId: String) -> MeetingSummary? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT meeting_id, title, overview, decisions_json, action_items_json, topics_json, questions_json, markdown FROM summary WHERE meeting_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let mId = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let overview = String(cString: sqlite3_column_text(stmt, 2))
                let decStr = String(cString: sqlite3_column_text(stmt, 3))
                let actStr = String(cString: sqlite3_column_text(stmt, 4))
                let topStr = String(cString: sqlite3_column_text(stmt, 5))
                let queStr = String(cString: sqlite3_column_text(stmt, 6))
                let markdown = String(cString: sqlite3_column_text(stmt, 7))
                
                let decisions = (try? JSONDecoder().decode([String].self, from: Data(decStr.utf8))) ?? []
                let actions = (try? JSONDecoder().decode([ActionItem].self, from: Data(actStr.utf8))) ?? []
                let topics = (try? JSONDecoder().decode([Topic].self, from: Data(topStr.utf8))) ?? []
                let questions = (try? JSONDecoder().decode([String].self, from: Data(queStr.utf8))) ?? []
                return MeetingSummary(meetingId: mId, title: title, overview: overview, decisions: decisions, actionItems: actions, topics: topics, questions: questions, markdown: markdown)
            }
        }
        return nil
    }
    
    // MARK: - Bookmarks
    
    public func saveBookmark(_ b: Bookmark) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO bookmark (id, meeting_id, timestamp, label, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            label = excluded.label,
            timestamp = excluded.timestamp;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 9, userInfo: [NSLocalizedDescriptionKey: "Prepare saveBookmark: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (b.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (b.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, b.timestamp)
        sqlite3_bind_text(stmt, 4, (b.label as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, b.createdAt.timeIntervalSince1970)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 9, userInfo: [NSLocalizedDescriptionKey: "Step saveBookmark: \(msg)"])
        }
    }
    
    public func listBookmarks(meetingId: String) -> [Bookmark] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Bookmark] = []
        let sql = "SELECT id, meeting_id, timestamp, label, created_at FROM bookmark WHERE meeting_id = ? ORDER BY timestamp ASC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let mId = String(cString: sqlite3_column_text(stmt, 1))
                let ts = sqlite3_column_double(stmt, 2)
                let label = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                list.append(Bookmark(id: id, meetingId: mId, timestamp: ts, label: label, createdAt: createdAt))
            }
        }
        return list
    }
    
    public func deleteBookmark(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "DELETE FROM bookmark WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 10, userInfo: [NSLocalizedDescriptionKey: "Prepare deleteBookmark: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 10, userInfo: [NSLocalizedDescriptionKey: "Step deleteBookmark: \(msg)"])
        }
    }
    
    // MARK: - Outbox
    
    public func enqueueOutboxItem(_ item: OutboxItem) throws -> OutboxItem {
        lock.lock()
        defer { lock.unlock() }
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction && sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK { throw databaseError("Begin outbox enqueue") }
        var committed = false
        defer { if ownsTransaction && !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        let sql = """
        SELECT id, meeting_id, destination_vault, source_revision, idempotency_key, status,
            retry_count, created_at, last_attempt_at, receipt_json, error_message, payload_json, destination_origin, grant_fingerprint, base_server_revision
        FROM outbox_item WHERE destination_vault = ? AND idempotency_key = ? AND destination_origin IS ? AND grant_fingerprint IS ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Prepare enqueue lookup") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (item.destinationVault as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (item.idempotencyKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let origin = item.destinationOrigin { sqlite3_bind_text(stmt, 3, (origin as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let grant = item.grantFingerprint { sqlite3_bind_text(stmt, 4, (grant as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
        let step = sqlite3_step(stmt)
        let result: OutboxItem
        if step == SQLITE_ROW {
            result = parseOutboxItem(stmt: stmt!)
        } else if step == SQLITE_DONE {
            try writeOutboxItem(item)
            result = item
        } else { throw databaseError("Read enqueue lookup") }
        if ownsTransaction && sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK { throw databaseError("Commit enqueue") }
        committed = true
        return result
    }

    public func saveOutboxItem(_ item: OutboxItem) throws {
        lock.lock()
        defer { lock.unlock() }
        
        try writeOutboxItem(item)
    }

    private func writeOutboxItem(_ item: OutboxItem) throws {
        let sql = """
        INSERT INTO outbox_item (
            id, meeting_id, destination_vault, source_revision,
            idempotency_key, status, retry_count, created_at,
            last_attempt_at, receipt_json, error_message, payload_json, destination_origin, grant_fingerprint, base_server_revision
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            status = excluded.status,
            retry_count = excluded.retry_count,
            last_attempt_at = excluded.last_attempt_at,
            receipt_json = excluded.receipt_json,
            error_message = excluded.error_message;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 11, userInfo: [NSLocalizedDescriptionKey: "Prepare saveOutboxItem: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        var receiptStr: String? = nil
        if let r = item.receipt, let data = try? JSONEncoder().encode(r) {
            receiptStr = String(data: data, encoding: .utf8)
        }
        
        sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (item.meetingId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (item.destinationVault as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(item.sourceRevision))
        sqlite3_bind_text(stmt, 5, (item.idempotencyKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, (item.status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(item.retryCount))
        sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSince1970)
        
        if let last = item.lastAttemptAt {
            sqlite3_bind_double(stmt, 9, last.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        
        if let rStr = receiptStr {
            sqlite3_bind_text(stmt, 10, (rStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        
        if let err = item.errorMessage {
            sqlite3_bind_text(stmt, 11, (err as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        
        sqlite3_bind_text(stmt, 12, (item.payloadJson as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let origin = item.destinationOrigin { sqlite3_bind_text(stmt, 13, (origin as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 13) }
        if let grant = item.grantFingerprint { sqlite3_bind_text(stmt, 14, (grant as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 14) }
        if let revision = item.baseServerRevision { sqlite3_bind_int64(stmt, 15, Int64(revision)) } else { sqlite3_bind_null(stmt, 15) }
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 11, userInfo: [NSLocalizedDescriptionKey: "Step saveOutboxItem: \(msg)"])
        }
    }
    
    public func getOutboxItem(id: String) -> OutboxItem? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        SELECT id, meeting_id, destination_vault, source_revision,
               idempotency_key, status, retry_count, created_at,
               last_attempt_at, receipt_json, error_message, payload_json, destination_origin, grant_fingerprint, base_server_revision
        FROM outbox_item WHERE id = ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return parseOutboxItem(stmt: stmt!)
            }
        }
        return nil
    }
    
    public func listOutboxItems(meetingId: String? = nil, status: OutboxStatus? = nil) -> [OutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [OutboxItem] = []
        var sql = """
        SELECT id, meeting_id, destination_vault, source_revision,
               idempotency_key, status, retry_count, created_at,
               last_attempt_at, receipt_json, error_message, payload_json, destination_origin, grant_fingerprint, base_server_revision
        FROM outbox_item WHERE 1=1
        """
        if meetingId != nil { sql += " AND meeting_id = ?" }
        if status != nil { sql += " AND status = ?" }
        sql += " ORDER BY created_at ASC"
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            if let mId = meetingId {
                sqlite3_bind_text(stmt, bindIdx, (mId as NSString).utf8String, -1, nil)
                bindIdx += 1
            }
            if let st = status {
                sqlite3_bind_text(stmt, bindIdx, (st.rawValue as NSString).utf8String, -1, nil)
                bindIdx += 1
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(parseOutboxItem(stmt: stmt!))
            }
        }
        return list
    }
    
    public func deleteOutboxItem(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "DELETE FROM outbox_item WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 12, userInfo: [NSLocalizedDescriptionKey: "Prepare deleteOutboxItem: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MinutesStore", code: 12, userInfo: [NSLocalizedDescriptionKey: "Step deleteOutboxItem: \(msg)"])
        }
    }
    
    private func parseOutboxItem(stmt: OpaquePointer) -> OutboxItem {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let mId = String(cString: sqlite3_column_text(stmt, 1))
        let vault = String(cString: sqlite3_column_text(stmt, 2))
        let rev = Int(sqlite3_column_int(stmt, 3))
        let idemKey = String(cString: sqlite3_column_text(stmt, 4))
        let statusRaw = String(cString: sqlite3_column_text(stmt, 5))
        let status = OutboxStatus(rawValue: statusRaw) ?? .pending
        let retries = Int(sqlite3_column_int(stmt, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        
        var lastAttempt: Date? = nil
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
            lastAttempt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        }
        
        var receipt: PrismReceipt? = nil
        if sqlite3_column_type(stmt, 9) != SQLITE_NULL, let text = sqlite3_column_text(stmt, 9) {
            let str = String(cString: text)
            if let data = str.data(using: .utf8) {
                receipt = try? JSONDecoder().decode(PrismReceipt.self, from: data)
            }
        }
        
        var errMsg: String? = nil
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL, let text = sqlite3_column_text(stmt, 10) {
            errMsg = String(cString: text)
        }
        
        let payload = String(cString: sqlite3_column_text(stmt, 11))
        
        return OutboxItem(
            id: id,
            meetingId: mId,
            destinationVault: vault,
            destinationOrigin: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
            grantFingerprint: sqlite3_column_text(stmt, 13).map { String(cString: $0) },
            baseServerRevision: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 14)),
            sourceRevision: rev,
            idempotencyKey: idemKey,
            status: status,
            retryCount: retries,
            createdAt: createdAt,
            lastAttemptAt: lastAttempt,
            receipt: receipt,
            errorMessage: errMsg,
            payloadJson: payload
        )
    }
    /// Atomically claims a row across independent SQLite connections/workers.
    public func claimOutboxItem(id: String, at: Date, staleBefore: Date) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE outbox_item SET status = 'sending', last_attempt_at = ?
        WHERE id = ? AND (status IN ('pending', 'failed_retryable', 'awaiting_receipt')
            OR (status = 'sending' AND (last_attempt_at IS NULL OR last_attempt_at < ?)));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Prepare outbox claim") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, staleBefore.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Claim outbox item") }
        return sqlite3_changes(db) == 1
    }

    /// A cancelled or reclaimed upload cannot be overwritten by a late response.
    public func finishOutboxClaim(_ item: OutboxItem, claimedAt: Date) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE outbox_item SET status = ?, retry_count = ?, receipt_json = ?, error_message = ?, last_attempt_at = ?
        WHERE id = ? AND status = 'sending' AND last_attempt_at = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Prepare finish outbox") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (item.status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(item.retryCount))
        if let receipt = item.receipt {
            let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
            sqlite3_bind_text(stmt, 3, (json as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 3) }
        if let message = item.errorMessage {
            sqlite3_bind_text(stmt, 4, (message as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_double(stmt, 5, (item.lastAttemptAt ?? claimedAt).timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, claimedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Finish outbox item") }
        return sqlite3_changes(db) == 1
    }

    public func resetOutboxForRetry(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE outbox_item SET status = 'pending', retry_count = 0, error_message = NULL
        WHERE id = ? AND status IN ('failed_retryable', 'awaiting_receipt', 'conflict', 'needs_sign_in', 'forbidden');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError("Prepare retry outbox") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError("Retry outbox") }
    }

}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Cross-device sync support

/// What a synced record last looked like, and CloudKit's change tag for it.
public struct SyncRecordState: Sendable, Equatable {
    public let name: String
    public let basePayload: Data?
    public let systemFields: Data?
    public init(name: String, basePayload: Data?, systemFields: Data?) {
        self.name = name; self.basePayload = basePayload; self.systemFields = systemFields
    }
}

extension MinutesStore {
    public func syncRecordState(_ name: String) throws -> SyncRecordState? {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT base_payload, system_fields FROM sync_record WHERE record_name=?", values: [name]) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read sync record") }
            guard code == SQLITE_ROW else { return nil }
            return SyncRecordState(name: name, basePayload: Self.blob(statement, 0), systemFields: Self.blob(statement, 1))
        }
    }

    public func listSyncRecordNames() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT record_name FROM sync_record ORDER BY record_name") { statement in
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
            return names
        }
    }

    /// Records a payload as agreed with the server; nil fields keep their stored value.
    public func saveSyncRecordState(_ name: String, basePayload: Data?, systemFields: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        var pointer: OpaquePointer?
        let sql = """
        INSERT INTO sync_record(record_name, base_payload, system_fields) VALUES (?,?,?)
        ON CONFLICT(record_name) DO UPDATE SET base_payload=COALESCE(excluded.base_payload, sync_record.base_payload),
            system_fields=COALESCE(excluded.system_fields, sync_record.system_fields)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw databaseError("Prepare sync record") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        for (index, data) in [(2, basePayload), (3, systemFields)] {
            if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index), $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) } }
            else { sqlite3_bind_null(statement, Int32(index)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError("Save sync record") }
    }

    /// Records changed here since they were last compared with the synced copy.
    public func listSyncDirtyRecordNames() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT record_name FROM sync_dirty ORDER BY record_name") { statement in
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
            return names
        }
    }

    public func clearSyncDirty(_ name: String) throws {
        try withImmediateTransaction { try folderWrite("DELETE FROM sync_dirty WHERE record_name=?", values: [name]) }
    }

    public func markSyncDirty(_ name: String) throws {
        try withImmediateTransaction { try folderWrite("INSERT OR IGNORE INTO sync_dirty(record_name) VALUES (?)", values: [name]) }
    }

    public func deleteSyncRecordState(_ name: String) throws {
        try withImmediateTransaction { try folderWrite("DELETE FROM sync_record WHERE record_name=?", values: [name]) }
    }

    /// Forgets every sync record, for example after signing out of iCloud.
    public func resetSyncRecordStates() throws {
        try withImmediateTransaction {
            try folderWrite("DELETE FROM sync_record")
            for sql in ["INSERT OR IGNORE INTO sync_dirty SELECT 'Meeting:'||id FROM meeting", "INSERT OR IGNORE INTO sync_dirty SELECT 'Audio:'||id FROM meeting",
                        "INSERT OR IGNORE INTO sync_dirty SELECT 'Folder:'||id FROM meeting_folder", "INSERT OR IGNORE INTO sync_dirty SELECT 'Person:'||id FROM person"] {
                try folderWrite(sql)
            }
        }
    }

    public func isMeetingInTrash(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try folderStatement("SELECT 1 FROM meeting_trash WHERE meeting_id=?", values: [id]) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw databaseError("Read trash") }
            return code == SQLITE_ROW
        }
    }

    /// Makes a meeting's transcript exactly `utterances`, removing rows no longer present.
    public func replaceUtterances(meetingId: String, with utterances: [Utterance]) throws {
        try withImmediateTransaction {
            try deleteChildren(table: "utterance", idColumn: "id", meetingId: meetingId, keep: utterances.map { String($0.id) })
            try saveUtterances(utterances)
        }
    }

    public func replaceBookmarks(meetingId: String, with bookmarks: [Bookmark]) throws {
        try withImmediateTransaction {
            try deleteChildren(table: "bookmark", idColumn: "id", meetingId: meetingId, keep: bookmarks.map(\.id))
            for bookmark in bookmarks { try saveBookmark(bookmark) }
        }
    }

    /// Speaker voice embeddings never leave a device, so a cluster arriving
    /// without one keeps the local embedding of the same cluster.
    public func replaceSpeakerClusters(meetingId: String, with clusters: [SpeakerCluster]) throws {
        try withImmediateTransaction {
            let local = Dictionary(listSpeakerClusters(meetingId: meetingId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            try deleteChildren(table: "speaker_cluster", idColumn: "id", meetingId: meetingId, keep: clusters.map(\.id))
            try saveSpeakerClusters(clusters.map { cluster in
                guard cluster.centroid.isEmpty, let existing = local[cluster.id] else { return cluster }
                var merged = cluster
                merged.centroid = existing.centroid
                merged.embeddingModel = existing.embeddingModel
                return merged
            })
        }
    }

    /// Inserts or updates a folder keeping its id (folders created on another device).
    public func upsertFolder(_ folder: MeetingFolder) throws {
        let fields = try checkedFolderFields(name: folder.name, description: folder.description)
        try withImmediateTransaction {
            try folderWrite("""
                INSERT INTO meeting_folder(id,name,description,sort_order,created_at) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, description=excluded.description, sort_order=excluded.sort_order, created_at=excluded.created_at
                """, values: [folder.id, fields.0, fields.1, String(folder.sortOrder), String(folder.createdAt.timeIntervalSince1970)])
        }
    }

    /// Text ids also match INTEGER ids: SQLite applies the column's affinity to IN values.
    private func deleteChildren(table: String, idColumn: String, meetingId: String, keep: [String]) throws {
        let placeholders = keep.map { _ in "?" }.joined(separator: ",")
        let filter = keep.isEmpty ? "" : " AND \(idColumn) NOT IN (\(placeholders))"
        try folderWrite("DELETE FROM \(table) WHERE meeting_id=?" + filter, values: [meetingId] + keep)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
