import Testing
import Foundation
@testable import MinutesCore

@Suite("SQLite Migration & Database Safety Tests")
struct DatabaseMigrationTests {
    
    @Test("Database migration is fully idempotent across multiple executions")
    func testMigrationIdempotency() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("idempotent_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        // Insert sample meeting & voiceprint
        let meeting = Meeting(title: "Migration Test Meeting", status: "recorded")
        try store.saveMeeting(meeting)
        
        let person = Person(displayName: "Test User", emails: ["test@user.org"])
        try store.savePerson(person)
        
        let vp = Voiceprint(personId: person.id, dim: 4, vector: [0.5, 0.5, -0.5, -0.5])
        try store.saveVoiceprint(vp)
        
        // Execute migrate() multiple times consecutively
        for _ in 1...5 {
            try store.migrate()
        }
        
        // Verify data integrity
        let fetchedM = store.getMeeting(id: meeting.id)
        #expect(fetchedM != nil)
        #expect(fetchedM?.title == "Migration Test Meeting")
        
        let allPeople = store.listPeople()
        #expect(allPeople.contains(where: { $0.id == person.id }))
        
        let allVPs = store.listVoiceprints()
        #expect(allVPs.contains(where: { $0.id == vp.id }))
    }
    
    @Test("Schema user_version persists and tracks database versions")
    func testSchemaVersionTracking() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("version_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        // Initial version after migrate is at least 1
        let v1 = store.currentSchemaVersion()
        #expect(v1 >= 1)
        
        // Bump version to 2
        try store.setSchemaVersion(2)
        #expect(store.currentSchemaVersion() == 2)
        
        // Re-open store at same path
        let storeReopened = try MinutesStore(dbPath: tempDb)
        #expect(storeReopened.currentSchemaVersion() == 2)
    }
    
    @Test("Voiceprint deletion removes target record without corrupting other voiceprints")
    func testVoiceprintDeletionSafety() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("delete_vp_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let person = Person(displayName: "User A")
        try store.savePerson(person)
        
        let vp1 = Voiceprint(id: "vp_to_keep", personId: person.id, dim: 2, vector: [1.0, 0.0])
        let vp2 = Voiceprint(id: "vp_to_delete", personId: person.id, dim: 2, vector: [0.0, 1.0])
        
        try store.saveVoiceprint(vp1)
        try store.saveVoiceprint(vp2)
        
        var vps = store.listVoiceprints()
        #expect(vps.count == 2)
        
        // Delete vp2
        try store.deleteVoiceprint(id: vp2.id)
        
        vps = store.listVoiceprints()
        #expect(vps.count == 1)
        #expect(vps.first?.id == "vp_to_keep")
        #expect(store.getVoiceprint(id: "vp_to_delete") == nil)
        #expect(store.getVoiceprint(id: "vp_to_keep") != nil)
    }
    
    @Test("Meeting deletion removes meeting record safely")
    func testMeetingDeletion() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("delete_m_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let m1 = Meeting(id: "m_1", title: "Meeting 1", status: "recorded")
        let m2 = Meeting(id: "m_2", title: "Meeting 2", status: "recorded")
        
        try store.saveMeeting(m1)
        try store.saveMeeting(m2)
        
        var meetings = store.listMeetings()
        #expect(meetings.count == 2)
        
        try store.deleteMeeting(id: "m_1")
        meetings = store.listMeetings()
        #expect(meetings.count == 1)
        #expect(meetings.first?.id == "m_2")
        #expect(store.getMeeting(id: "m_1") == nil)
    }
}
