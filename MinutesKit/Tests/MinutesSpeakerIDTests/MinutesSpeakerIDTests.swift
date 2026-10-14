import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeakerID

@Suite("MinutesSpeakerID Tests")
struct MinutesSpeakerIDTests {
    @Test("VectorMath computes cosine similarity accurately")
    func testCosineSimilarity() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0, 0.0]
        let v3: [Float] = [0.0, 1.0, 0.0]
        
        let simIdentical = VectorMath.cosineSimilarity(v1, v2)
        let simOrthogonal = VectorMath.cosineSimilarity(v1, v3)
        
        #expect(abs(simIdentical - 1.0) < 1e-5)
        #expect(abs(simOrthogonal - 0.0) < 1e-5)
    }
    
    @Test("SpeakerMatcher assigns candidates with prior bonus")
    func testSpeakerMatcher() {
        let personA = Person(id: "p_a", displayName: "Alice")
        let personB = Person(id: "p_b", displayName: "Bob")
        
        let vpA = Voiceprint(personId: personA.id, dim: 2, vector: [1.0, 0.0])
        let vpB = Voiceprint(personId: personB.id, dim: 2, vector: [0.0, 1.0])
        
        let cluster1 = SpeakerCluster(id: "c1", meetingId: "m", trackId: "t", label: "Speaker 1", centroid: [0.95, 0.05])
        let cluster2 = SpeakerCluster(id: "c2", meetingId: "m", trackId: "t", label: "Speaker 2", centroid: [0.05, 0.95])
        
        let matcher = SpeakerMatcher(autoThreshold: 0.65, suggestThreshold: 0.50)
        let matches = matcher.match(
            clusters: [cluster1, cluster2],
            people: [personA, personB],
            voiceprints: [vpA, vpB],
            attendeePersonIds: [personA.id]
        )
        
        #expect(matches.count == 2)
        let match1 = matches.first(where: { $0.clusterId == "c1" })
        let match2 = matches.first(where: { $0.clusterId == "c2" })
        
        #expect(match1?.personId == personA.id)
        #expect(match1?.assignment == "auto")
        #expect(match2?.personId == personB.id)
        #expect(match2?.assignment == "auto")
    }
}
