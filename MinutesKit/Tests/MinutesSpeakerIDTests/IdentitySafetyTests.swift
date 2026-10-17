import Foundation
import Testing
import MinutesCore
import MinutesSpeakerID

@Suite("Speaker identity safety")
struct IdentitySafetyTests {
    @Test("Legacy synthetic vectors never identify people in production")
    func legacyEmbeddingsAreRejected() {
        let person = Person(id: "p", displayName: "Person")
        let cluster = SpeakerCluster(id: "c", meetingId: "m", trackId: "t", label: "Speaker", centroid: [1, 0], speechSeconds: 20)
        let print = Voiceprint(personId: person.id, dim: 2, vector: [1, 0])
        let result = SpeakerMatcher().match(clusters: [cluster], people: [person], voiceprints: [print], attendeePersonIds: [person.id])
        #expect(result.first?.personId == nil)
        #expect(result.first?.assignment == "unassigned")
    }
    @Test("Compatible trained profiles remain suggestions until automatic thresholds are validated")
    func compatibleProfileIsSuggestion() throws {
        let person = Person(id: "p", displayName: "Person")
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        let cluster = SpeakerCluster(id: "c", meetingId: "m", trackId: "t", label: "Speaker", centroid: vector, speechSeconds: 20, embeddingModel: SpeakerEmbeddingModel.trainedID)
        let print = Voiceprint(personId: person.id, model: SpeakerEmbeddingModel.trainedID, dim: 256, vector: vector)
        let match = SpeakerMatcher().match(clusters: [cluster], people: [person], voiceprints: [print], attendeePersonIds: [person.id]).first
        #expect(match?.assignment == "suggested")
        #expect(match?.personId == person.id)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("db").path)
        try store.saveMeeting(Meeting(id: "m", title: "Provenance"))
        try store.saveSpeakerClusters([cluster])
        #expect(store.listSpeakerClusters(meetingId: "m").first?.embeddingModel == SpeakerEmbeddingModel.trainedID)
    }

    @Test("Ambiguous trained profiles and incompatible model versions abstain")
    func ambiguousAndWrongModelsAbstain() {
        let a = Person(id: "a", displayName: "A"), b = Person(id: "b", displayName: "B")
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        let cluster = SpeakerCluster(id: "c", meetingId: "m", trackId: "t", label: "Speaker", centroid: vector, speechSeconds: 20, embeddingModel: SpeakerEmbeddingModel.trainedID)
        let profiles = [a,b].map { Voiceprint(personId: $0.id, model: SpeakerEmbeddingModel.trainedID, dim: 256, vector: vector) }
        #expect(SpeakerMatcher().match(clusters: [cluster], people: [a,b], voiceprints: profiles, attendeePersonIds: []).first?.personId == nil)
        let old = Voiceprint(personId: a.id, model: "wespeaker_v2", dim: 256, vector: vector)
        #expect(SpeakerMatcher().match(clusters: [cluster], people: [a], voiceprints: [old], attendeePersonIds: [a.id]).first?.personId == nil)
    }

}
