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
    
    @Test("Bug 1 Regression: Multi-meeting utterances with identical IDs are isolated and not overwritten")
    func testMultiMeetingUtteranceIsolation() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("regression_m_iso_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let m1 = Meeting(id: "m_1", title: "Meeting 1", status: "recorded")
        let m2 = Meeting(id: "m_2", title: "Meeting 2", status: "recorded")
        try store.saveMeeting(m1)
        try store.saveMeeting(m2)
        
        let c1 = SpeakerCluster(id: "c_1", meetingId: m1.id, trackId: "t1", label: "Speaker 1")
        let c2 = SpeakerCluster(id: "c_2", meetingId: m2.id, trackId: "t1", label: "Speaker 2")
        try store.saveSpeakerClusters([c1, c2])
        
        // Meeting 1 utterances (IDs 1 and 2)
        let m1Utterance1 = Utterance(id: 1, meetingId: m1.id, clusterId: c1.id, speakerName: "Alice", start: 0.0, end: 5.0, text: "Meeting 1: First topic")
        let m1Utterance2 = Utterance(id: 2, meetingId: m1.id, clusterId: c1.id, speakerName: "Alice", start: 5.0, end: 10.0, text: "Meeting 1: Second topic")
        try store.saveUtterances([m1Utterance1, m1Utterance2])
        
        #expect(store.listUtterances(meetingId: m1.id).count == 2)
        
        // Meeting 2 utterances with colliding sequential IDs (IDs 1 and 2)
        let m2Utterance1 = Utterance(id: 1, meetingId: m2.id, clusterId: c2.id, speakerName: "Bob", start: 0.0, end: 4.0, text: "Meeting 2: Kickoff")
        let m2Utterance2 = Utterance(id: 2, meetingId: m2.id, clusterId: c2.id, speakerName: "Bob", start: 4.0, end: 8.0, text: "Meeting 2: Adjourned")
        try store.saveUtterances([m2Utterance1, m2Utterance2])
        
        // CRITICAL CHECK: Meeting 1 utterances must NOT have been overwritten
        let m1Remaining = store.listUtterances(meetingId: m1.id)
        #expect(m1Remaining.count == 2, "Meeting 1 lost utterances due to non-composite primary key collision!")
        #expect(m1Remaining.first?.text == "Meeting 1: First topic")
        #expect(m1Remaining.last?.text == "Meeting 1: Second topic")
        
        let m2Remaining = store.listUtterances(meetingId: m2.id)
        #expect(m2Remaining.count == 2)
        #expect(m2Remaining.first?.text == "Meeting 2: Kickoff")
        #expect(m2Remaining.last?.text == "Meeting 2: Adjourned")
    }
    
    @Test("Bug 2 Regression: saveSpeakerClusters ON CONFLICT updates centroid and speech_seconds")
    func testSpeakerClusterUpsertPreservesCentroidAndDuration() throws {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("regression_cluster_\(UUID().uuidString).db")
        let store = try MinutesStore(dbPath: tempDb)
        
        let m = Meeting(id: "m_cluster_test", title: "Cluster Test", status: "recorded")
        try store.saveMeeting(m)
        
        let initialCentroid: [Float] = [1.0, 0.0, 0.0]
        let cluster = SpeakerCluster(
            id: "c_update_test",
            meetingId: m.id,
            trackId: "t1",
            label: "Initial Speaker",
            centroid: initialCentroid,
            speechSeconds: 30.0,
            personId: nil,
            assignment: "suggested",
            confidence: 0.5
        )
        try store.saveSpeakerClusters([cluster])
        
        let initialFetch = store.listSpeakerClusters(meetingId: m.id).first
        #expect(initialFetch?.speechSeconds == 30.0)
        #expect(initialFetch?.centroid == initialCentroid)
        
        // Re-save with updated centroid vector and increased speech seconds
        let updatedCentroid: [Float] = [0.0, 1.0, 0.0]
        var clusterUpdate = cluster
        clusterUpdate.label = "Refined Speaker"
        clusterUpdate.centroid = updatedCentroid
        clusterUpdate.speechSeconds = 95.5
        clusterUpdate.confidence = 0.95
        try store.saveSpeakerClusters([clusterUpdate])
        
        // CRITICAL CHECK: Verify centroid and speechSeconds were updated, not dropped
        let updatedFetch = store.listSpeakerClusters(meetingId: m.id).first
        #expect(updatedFetch != nil)
        #expect(updatedFetch?.label == "Refined Speaker")
        #expect(updatedFetch?.centroid == updatedCentroid, "Centroid was not updated in speaker_cluster ON CONFLICT!")
        #expect(updatedFetch?.speechSeconds == 95.5, "speech_seconds was not updated in speaker_cluster ON CONFLICT!")
        #expect(updatedFetch?.confidence == 0.95)
    }
}
