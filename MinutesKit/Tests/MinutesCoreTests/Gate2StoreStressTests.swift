import Testing
import Foundation
import SQLite3
@testable import MinutesCore

@Suite("Gate 2 Store Adversarial Stress Tests")
struct Gate2StoreStressTests {
    
    @Test("Stress Test 1: 5 meetings with 100 identical sequential IDs each (500 utterances total)")
    func testMultiMeetingUtteranceStressScale() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("gate2_scale_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let numMeetings = 5
        let numUtterances = 100
        
        var meetings: [Meeting] = []
        for i in 1...numMeetings {
            let m = Meeting(id: "m_scale_\(i)", title: "Scale Meeting \(i)", status: "recorded")
            try store.saveMeeting(m)
            meetings.append(m)
        }
        
        for (mIdx, m) in meetings.enumerated() {
            let cluster = SpeakerCluster(id: "c_\(m.id)", meetingId: m.id, trackId: "t1", label: "Speaker \(mIdx + 1)")
            try store.saveSpeakerClusters([cluster])
            
            var batch: [Utterance] = []
            for uId in 1...numUtterances {
                let u = Utterance(
                    id: uId,
                    meetingId: m.id,
                    clusterId: cluster.id,
                    speakerName: "Speaker \(mIdx + 1)",
                    start: Double(uId * 2),
                    end: Double(uId * 2 + 1),
                    text: "Utterance \(uId) for meeting \(m.id)"
                )
                batch.append(u)
            }
            try store.saveUtterances(batch)
        }
        
        // EMPIRICAL VERIFICATION: Every single meeting must have exactly 100 utterances
        for m in meetings {
            let fetched = store.listUtterances(meetingId: m.id)
            #expect(fetched.count == numUtterances, "Meeting \(m.id) lost utterances due to primary key collision!")
            for (idx, u) in fetched.enumerated() {
                let expectedId = idx + 1
                #expect(u.id == expectedId)
                #expect(u.text == "Utterance \(expectedId) for meeting \(m.id)")
            }
        }
        
        // EMPIRICAL VERIFICATION: In-place update to Meeting 1, Utterance 42
        let m1 = meetings[0]
        var m1List = store.listUtterances(meetingId: m1.id)
        var u42 = m1List.first(where: { $0.id == 42 })!
        u42.text = "REVISED TEXT FOR UTTERANCE 42"
        try store.saveUtterances([u42])
        
        let m1Updated = store.listUtterances(meetingId: m1.id)
        #expect(m1Updated.first(where: { $0.id == 42 })?.text == "REVISED TEXT FOR UTTERANCE 42")
        
        // Verify meetings 2..5 utterance 42 were NOT modified
        for m in meetings.dropFirst() {
            let otherList = store.listUtterances(meetingId: m.id)
            let otherU42 = otherList.first(where: { $0.id == 42 })
            #expect(otherU42?.text == "Utterance 42 for meeting \(m.id)")
        }
        
        // EMPIRICAL VERIFICATION: Cascade deletion of Meeting 1
        try store.deleteMeeting(id: m1.id)
        #expect(store.listUtterances(meetingId: m1.id).isEmpty)
        
        for m in meetings.dropFirst() {
            #expect(store.listUtterances(meetingId: m.id).count == numUtterances)
        }
    }
    
    @Test("Stress Test 2: SpeakerCluster upsert preserves 256-dim centroid vector and speech seconds across multiple mutations")
    func testSpeakerClusterUpsertMultipleMutations() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("gate2_cluster_mutation_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let m = Meeting(id: "m_cluster_mut", title: "Cluster Mutation Meeting", status: "recorded")
        try store.saveMeeting(m)
        
        let dim = 256
        var v1 = [Float](repeating: 0.0, count: dim)
        v1[0] = 1.0
        
        var cluster = SpeakerCluster(
            id: "c_mut_1",
            meetingId: m.id,
            trackId: "t1",
            label: "Speaker 1",
            centroid: v1,
            speechSeconds: 15.0,
            personId: nil,
            assignment: "unassigned",
            confidence: 0.3
        )
        try store.saveSpeakerClusters([cluster])
        
        var fetched = store.listSpeakerClusters(meetingId: m.id).first
        #expect(fetched?.speechSeconds == 15.0)
        #expect(fetched?.centroid == v1)
        
        // Mutation 1
        var v2 = [Float](repeating: 0.0, count: dim)
        v2[1] = 1.0
        cluster.label = "Speaker 1 Refined"
        cluster.centroid = v2
        cluster.speechSeconds = 65.5
        cluster.assignment = "suggested"
        cluster.confidence = 0.75
        try store.saveSpeakerClusters([cluster])
        
        fetched = store.listSpeakerClusters(meetingId: m.id).first
        #expect(fetched?.speechSeconds == 65.5)
        #expect(fetched?.centroid == v2)
        #expect(fetched?.label == "Speaker 1 Refined")
        #expect(fetched?.assignment == "suggested")
        
        // Mutation 2
        var v3 = [Float](repeating: 0.0, count: dim)
        v3[2] = 0.7071
        v3[3] = 0.7071
        cluster.centroid = v3
        cluster.speechSeconds = 180.25
        cluster.assignment = "auto"
        cluster.confidence = 0.98
        try store.saveSpeakerClusters([cluster])
        
        fetched = store.listSpeakerClusters(meetingId: m.id).first
        #expect(fetched?.speechSeconds == 180.25)
        #expect(fetched?.centroid == v3)
        #expect(fetched?.assignment == "auto")
    }
    
    @Test("Stress Test 5: Legacy SQLite database migration automatically upgrades to composite PK and preserves existing data")
    func testLegacyMigrationPreservesExistingData() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("legacy_mig_\(UUID().uuidString).db")
        
        // 1. Manually construct legacy DB with single-column primary key
        var db: OpaquePointer?
        guard sqlite3_open(tempDb, &db) == SQLITE_OK else {
            Issue.record("Failed to create temporary SQLite DB")
            return
        }
        
        let legacySetup = """
        CREATE TABLE meeting (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL DEFAULT 0.0,
            ended_at REAL,
            platform TEXT NOT NULL DEFAULT 'local',
            calendar_event_id TEXT,
            conference_url TEXT,
            status TEXT NOT NULL DEFAULT 'recorded',
            device TEXT,
            user_notes TEXT
        );
        CREATE TABLE utterance (
            id INTEGER PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            cluster_id TEXT NOT NULL,
            speaker_name TEXT NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            text TEXT NOT NULL,
            words_json TEXT NOT NULL DEFAULT '[]'
        );
        INSERT INTO meeting (id, title) VALUES ('m_legacy_1', 'Legacy 1');
        INSERT INTO meeting (id, title) VALUES ('m_legacy_2', 'Legacy 2');
        INSERT INTO utterance VALUES (1, 'm_legacy_1', 'c1', 'Alice', 0.0, 5.0, 'Legacy M1 U1', '[]');
        INSERT INTO utterance VALUES (2, 'm_legacy_1', 'c1', 'Alice', 5.0, 10.0, 'Legacy M1 U2', '[]');
        INSERT INTO utterance VALUES (3, 'm_legacy_2', 'c2', 'Bob', 0.0, 4.0, 'Legacy M2 U3', '[]');
        """
        sqlite3_exec(db, legacySetup, nil, nil, nil)
        sqlite3_close(db)
        
        // 2. Open with MinutesStore to trigger migration
        let store = try MinutesStore(dbPath: tempDb)
        
        // 3. Verify legacy data survived migration
        let m1Utterances = store.listUtterances(meetingId: "m_legacy_1")
        #expect(m1Utterances.count == 2)
        #expect(m1Utterances[0].text == "Legacy M1 U1")
        #expect(m1Utterances[1].text == "Legacy M1 U2")
        
        let m2Utterances = store.listUtterances(meetingId: "m_legacy_2")
        #expect(m2Utterances.count == 1)
        #expect(m2Utterances[0].text == "Legacy M2 U3")
        
        // 4. Verify that now m_legacy_2 can insert utterance with ID 1 without colliding with m_legacy_1
        let newU1 = Utterance(id: 1, meetingId: "m_legacy_2", clusterId: "c2", speakerName: "Bob", start: 10.0, end: 15.0, text: "Legacy M2 New U1")
        try store.saveUtterances([newU1])
        
        let m1After = store.listUtterances(meetingId: "m_legacy_1")
        #expect(m1After.count == 2)
        #expect(m1After.first(where: { $0.id == 1 })?.text == "Legacy M1 U1")
        
        let m2After = store.listUtterances(meetingId: "m_legacy_2")
        #expect(m2After.count == 2)
        #expect(m2After.first(where: { $0.id == 1 })?.text == "Legacy M2 New U1")
        
        // 5. Test idempotency: re-instantiate store on same db
        let store2 = try MinutesStore(dbPath: tempDb)
        #expect(store2.listUtterances(meetingId: "m_legacy_1").count == 2)
        #expect(store2.listUtterances(meetingId: "m_legacy_2").count == 2)
    }
}
