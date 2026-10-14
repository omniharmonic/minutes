import Foundation
import SQLite3

public final class MinutesStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    
    public init(dbPath: String) throws {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        var handle: OpaquePointer?
        if sqlite3_open(dbPath, &handle) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw NSError(domain: "MinutesStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open db failed: \(msg)"])
        }
        self.db = handle
        try migrate()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
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
            user_notes TEXT
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
    
    public func saveMeeting(_ m: Meeting) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO meeting (id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            ended_at = excluded.ended_at,
            status = excluded.status,
            user_notes = excluded.user_notes;
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
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "MinutesStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Save meeting error: \(msg)"])
            }
        }
    }
    
    public func getMeeting(id: String) -> Meeting? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes FROM meeting WHERE id = ?"
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
                return Meeting(id: mId, title: title, startedAt: started, endedAt: ended, platform: platform, calendarEventId: cal, conferenceURL: conf, status: status, device: dev, userNotes: notes)
            }
        }
        return nil
    }
    
    public func listMeetings() -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [Meeting] = []
        let sql = "SELECT id, title, started_at, ended_at, platform, calendar_event_id, conference_url, status, device, user_notes FROM meeting ORDER BY started_at DESC"
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
                list.append(Meeting(id: mId, title: title, startedAt: started, endedAt: ended, platform: platform, calendarEventId: cal, conferenceURL: conf, status: status, device: dev, userNotes: notes))
            }
        }
        return list
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
        INSERT INTO speaker_cluster (id, meeting_id, track_id, label, centroid, speech_seconds, person_id, assignment, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            label = excluded.label,
            centroid = excluded.centroid,
            speech_seconds = excluded.speech_seconds,
            person_id = excluded.person_id,
            assignment = excluded.assignment,
            confidence = excluded.confidence;
        """
        for c in clusters {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (c.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (c.meetingId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (c.trackId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (c.label as NSString).utf8String, -1, nil)
                
                let byteCount = c.centroid.count * MemoryLayout<Float>.size
                if byteCount > 0 {
                    _ = c.centroid.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(byteCount), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                
                sqlite3_bind_double(stmt, 6, c.speechSeconds)
                if let pid = c.personId { sqlite3_bind_text(stmt, 7, (pid as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 7) }
                sqlite3_bind_text(stmt, 8, (c.assignment as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 9, c.confidence)
                _ = sqlite3_step(stmt)
            }
        }
    }
    
    public func listSpeakerClusters(meetingId: String) -> [SpeakerCluster] {
        lock.lock()
        defer { lock.unlock() }
        
        var list: [SpeakerCluster] = []
        let sql = "SELECT id, meeting_id, track_id, label, centroid, speech_seconds, person_id, assignment, confidence FROM speaker_cluster WHERE meeting_id = ?"
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
                list.append(SpeakerCluster(id: id, meetingId: mId, trackId: tId, label: label, centroid: centroid, speechSeconds: speechSeconds, personId: personId, assignment: assignment, confidence: confidence))
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
        for u in utterances {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                let wordsData = (try? JSONEncoder().encode(u.words)) ?? Data("[]".utf8)
                let wordsStr = String(data: wordsData, encoding: .utf8) ?? "[]"
                
                sqlite3_bind_int(stmt, 1, Int32(u.id))
                sqlite3_bind_text(stmt, 2, (u.meetingId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (u.clusterId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (u.speakerName as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 5, u.start)
                sqlite3_bind_double(stmt, 6, u.end)
                sqlite3_bind_text(stmt, 7, (u.text as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 8, (wordsStr as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
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
            
            sqlite3_bind_text(stmt, 1, (s.meetingId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (s.title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (s.overview as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (decStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (actStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (topStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (queStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 8, (s.markdown as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
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
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
