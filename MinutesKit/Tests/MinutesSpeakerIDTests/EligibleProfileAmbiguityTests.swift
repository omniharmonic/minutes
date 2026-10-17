import Foundation
import Testing
import MinutesCore
import MinutesSpeakerID

@Suite("Automatic identity uses only eligible profile scores")
struct EligibleProfileAmbiguityTests {
    private func vector(_ similarity: Float) -> [Float] {
        var value = Array(repeating: Float.zero, count: 256)
        value[0] = similarity
        value[1] = sqrt(max(0, 1 - similarity * similarity))
        return value
    }
    private func cluster() -> SpeakerCluster {
        SpeakerCluster(id: "c", meetingId: "m", trackId: "track", label: "Speaker 1",
                       centroid: vector(1), speechSeconds: 10, embeddingModel: SpeakerEmbeddingModel.trainedID)
    }
    private func profile(_ person: String, similarity: Float, seconds: Double) -> Voiceprint {
        Voiceprint(personId: person, model: SpeakerEmbeddingModel.trainedID,
                   vector: vector(similarity), speechSeconds: seconds)
    }
    @Test("A short profile cannot manufacture an automatic margin over another learned voice")
    func shortProfileCannotInflateMargin() {
        let profiles = [profile("a", similarity: 0.95, seconds: 30),
                        profile("a", similarity: 1, seconds: 1),
                        profile("b", similarity: 0.85, seconds: 30)]
        let matcher = SpeakerMatcher(autoThreshold: 0.88, suggestThreshold: 0.88,
                                     allowAutomaticAssignment: true, minimumMargin: 0.12)
        let result = matcher.match(clusters: [cluster()], people: [Person(id: "a", displayName: "A"), Person(id: "b", displayName: "B")],
                                   voiceprints: profiles, attendeePersonIds: ["a"])
        #expect(result.first?.assignment == "unassigned")
        #expect(result.first?.personId == nil)
    }
    @Test("Automatic confidence uses the eligible long profile rather than a short exact match")
    func automaticScoreUsesLearnedEvidence() {
        let profiles = [profile("a", similarity: 0.95, seconds: 30), profile("a", similarity: 1, seconds: 1)]
        let matcher = SpeakerMatcher(autoThreshold: 0.88, suggestThreshold: 0.88, allowAutomaticAssignment: true)
        let result = matcher.match(clusters: [cluster()], people: [Person(id: "a", displayName: "A")],
                                   voiceprints: profiles, attendeePersonIds: [])
        #expect(result.first?.assignment == "auto")
        #expect(abs((result.first?.confidence ?? 0) - 0.95) < 0.0001)
    }
    @Test("A short competing profile still blocks an ambiguous automatic identity")
    func shortCompetingProfileRemainsNegativeEvidence() {
        let profiles = [profile("a", similarity: 0.95, seconds: 30), profile("b", similarity: 1, seconds: 1)]
        let matcher = SpeakerMatcher(autoThreshold: 0.88, suggestThreshold: 0.88, allowAutomaticAssignment: true)
        let result = matcher.match(clusters: [cluster()], people: [Person(id: "a", displayName: "A"), Person(id: "b", displayName: "B")],
                                   voiceprints: profiles, attendeePersonIds: [])
        #expect(result.first?.assignment == "unassigned")
    }

}
