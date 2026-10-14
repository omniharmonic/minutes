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
    
    @Test("Bug 3 Regression: SpeakerMatcher applies attendee bonus exactly once")
    func testSpeakerMatcherSingleAttendeeBonus() {
        let personA = Person(id: "p_a", displayName: "Alice")
        // Alice has voiceprint pointing along [1.0, 0.0]
        let vpA = Voiceprint(personId: personA.id, dim: 2, vector: [1.0, 0.0])
        
        // Candidate cluster has similarity 0.53 with Alice: [0.53, sqrt(1 - 0.53^2)]
        let yCoord = Float(sqrt(1.0 - 0.53 * 0.53))
        let clusterCandidate = SpeakerCluster(
            id: "c_cand",
            meetingId: "m",
            trackId: "t",
            label: "Speaker ?",
            centroid: [0.53, yCoord]
        )
        
        let autoThresh = 0.68
        let suggThresh = 0.52
        let bonus = 0.08
        let matcher = SpeakerMatcher(autoThreshold: autoThresh, suggestThreshold: suggThresh, attendeeBonus: bonus)
        
        // CASE 1: Alice IS an attendee
        // Raw similarity: 0.53
        // Effective score with single bonus: 0.53 + 0.08 = 0.61
        // Auto threshold: 0.68. Since 0.61 < 0.68, assignment MUST NOT BE "auto"!
        // Suggested threshold: 0.52. Since 0.61 >= 0.52, assignment MUST BE "suggested".
        let attendeeMatches = matcher.match(
            clusters: [clusterCandidate],
            people: [personA],
            voiceprints: [vpA],
            attendeePersonIds: [personA.id]
        )
        
        let match1 = attendeeMatches.first(where: { $0.clusterId == "c_cand" })
        #expect(match1 != nil)
        #expect(match1?.personId == personA.id)
        #expect(match1?.assignment == "suggested", "Double bonus bug: similarity 0.53 was incorrectly auto-matched because bonus was counted twice!")
        #expect(match1?.assignment != "auto")
        
        // CASE 2: High raw similarity (0.62) with attendee bonus reaches auto
        // 0.62 + 0.08 = 0.70 >= 0.68 -> "auto"
        let yCoordHigh = Float(sqrt(1.0 - 0.62 * 0.62))
        let clusterHigh = SpeakerCluster(
            id: "c_high",
            meetingId: "m",
            trackId: "t",
            label: "Speaker High",
            centroid: [0.62, yCoordHigh]
        )
        let highMatches = matcher.match(
            clusters: [clusterHigh],
            people: [personA],
            voiceprints: [vpA],
            attendeePersonIds: [personA.id]
        )
        let matchHigh = highMatches.first(where: { $0.clusterId == "c_high" })
        #expect(matchHigh?.assignment == "auto")
    }
}
