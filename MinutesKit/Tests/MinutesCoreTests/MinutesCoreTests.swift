import Testing
import Foundation
@testable import MinutesCore

@Suite("MinutesCore Store Tests")
struct MinutesCoreStoreTests {
    @Test("Store CRUD for Meeting, Person, Voiceprint, and Utterance")
    func testStoreCRUD() throws {
        let tempDir = NSTemporaryDirectory()
        let dbPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: dbPath)
        
        // 1. Meeting
        let m = Meeting(title: "Architecture Sync", status: "recorded")
        try store.saveMeeting(m)
        let fetchedM = store.getMeeting(id: m.id)
        #expect(fetchedM != nil)
        #expect(fetchedM?.title == "Architecture Sync")
        
        // 2. Person
        let p = Person(displayName: "Ana Lopez", emails: ["ana@stripe.com"])
        try store.savePerson(p)
        let people = store.listPeople()
        #expect(people.contains(where: { $0.id == p.id && $0.displayName == "Ana Lopez" }))
        
        // 3. Voiceprint
        let vec: [Float] = [1.0, 0.0, 0.5, -0.5]
        let vp = Voiceprint(personId: p.id, dim: 4, vector: vec)
        try store.saveVoiceprint(vp)
        let vps = store.listVoiceprints()
        #expect(vps.contains(where: { $0.personId == p.id && $0.dim == 4 }))
        
        // 4. Clusters & Utterances
        let cluster = SpeakerCluster(meetingId: m.id, trackId: "t1", label: "Speaker 1")
        try store.saveSpeakerClusters([cluster])
        let clusters = store.listSpeakerClusters(meetingId: m.id)
        #expect(clusters.count == 1)
        
        let u = Utterance(id: 1, meetingId: m.id, clusterId: cluster.id, speakerName: "Ana Lopez", start: 0.0, end: 5.0, text: "Let's review the proposal.")
        try store.saveUtterances([u])
        let utterances = store.listUtterances(meetingId: m.id)
        #expect(utterances.count == 1)
        #expect(utterances.first?.text == "Let's review the proposal.")
    }
}
