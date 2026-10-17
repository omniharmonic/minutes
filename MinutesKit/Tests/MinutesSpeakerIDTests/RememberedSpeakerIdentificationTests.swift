import Foundation
import Testing
import MinutesCore
import MinutesSpeakerID

struct RememberedSpeakerIdentificationTests {
    private let person = Person(id: "remembered-person", displayName: "Remembered person")
    private func vector(_ similarity: Double) -> [Float] {
        [Float(similarity), Float(sqrt(max(0, 1 - similarity * similarity)))] + Array(repeating: 0, count: 254)
    }
    private func cluster(_ similarity: Double = 1) -> SpeakerCluster {
        SpeakerCluster(id: "cluster", meetingId: "meeting", trackId: "track", label: "Speaker 1",
                       centroid: vector(similarity), speechSeconds: 12, embeddingModel: SpeakerEmbeddingModel.trainedID)
    }
    private func profile(seconds: Double = 30) -> Voiceprint {
        Voiceprint(personId: person.id, model: SpeakerEmbeddingModel.trainedID, vector: vector(1), speechSeconds: seconds)
    }
    @Test func attendeePresenceCannotPromoteWeakAcousticsToAutomaticIdentity() {
        let matcher = SpeakerMatcher(autoThreshold: 0.88, attendeeBonus: 0.08, allowAutomaticAssignment: true)
        let match = matcher.match(clusters: [cluster(0.82)], people: [person], voiceprints: [profile()], attendeePersonIds: [person.id]).first
        #expect(match?.assignment != "auto")
    }
    @Test func insufficientRememberedSpeechCannotAutomaticallyNameAPerson() {
        let matcher = SpeakerMatcher(allowAutomaticAssignment: true)
        let match = matcher.match(clusters: [cluster()], people: [person], voiceprints: [profile(seconds: 0)], attendeePersonIds: []).first
        #expect(match?.assignment != "auto")
    }
}

extension RememberedSpeakerIdentificationTests {
    @Test func strongRememberedVoicePrefillsNamesWithoutClaimingHumanConfirmation() {
        let input = cluster()
        let utterance = Utterance(id: 1, meetingId: "meeting", clusterId: input.id, speakerName: input.label,
                                  start: 0, end: 2, text: "Synthetic test words")
        let result = RememberedSpeakerIdentification.apply(clusters: [input], utterances: [utterance],
                                                           people: [person], voiceprints: [profile()])
        #expect(result.clusters.first?.personId == person.id)
        #expect(result.clusters.first?.label == person.displayName)
        #expect(result.clusters.first?.assignment == "auto")
        #expect(result.utterances.first?.speakerName == person.displayName)
        #expect(result.utterances.first?.text == utterance.text)
    }
    @Test func ambiguousNovelAndInvalidProfilesAbstainEvenForCalendarAttendees() {
        let other = Person(id: "other", displayName: "Other person")
        let duplicate = Voiceprint(personId: other.id, model: SpeakerEmbeddingModel.trainedID,
                                   vector: vector(1), speechSeconds: 30)
        let old = Voiceprint(personId: person.id, model: "legacy-synthetic", vector: vector(1), speechSeconds: 30)
        let invalid = Voiceprint(personId: person.id, model: SpeakerEmbeddingModel.trainedID,
                                 vector: Array(repeating: .nan, count: 256), speechSeconds: 30)
        for (input, profiles) in [(cluster(), [profile(), duplicate]), (cluster(0.4), [profile()]),
                                   (cluster(), [old]), (cluster(), [invalid]), (cluster(), [profile(seconds: 2)])] {
            let result = RememberedSpeakerIdentification.apply(clusters: [input], utterances: [], people: [person, other],
                                                               voiceprints: profiles, attendeePersonIDs: [person.id])
            #expect(result.clusters.first?.personId == nil)
            #expect(result.clusters.first?.assignment != "auto")
        }
    }
    @Test func explicitHumanAssignmentsAndUnknownDecisionsRemainUnchanged() {
        for assignment in ["user", "unknown"] {
            var input = cluster()
            input.assignment = assignment
            input.label = "User choice"
            let result = RememberedSpeakerIdentification.apply(clusters: [input], utterances: [],
                                                               people: [person], voiceprints: [profile()])
            #expect(result.clusters.first?.label == "User choice")
            #expect(result.clusters.first?.assignment == assignment)
        }
    }
    @Test func fragmentedVoiceCanPrefillSeveralClustersWithoutCreatingPeopleOrProfiles() {
        let first = cluster()
        var second = cluster()
        second = SpeakerCluster(id: "second-cluster", meetingId: second.meetingId, trackId: second.trackId,
                                label: "Speaker 2", centroid: second.centroid, speechSeconds: second.speechSeconds,
                                embeddingModel: second.embeddingModel)
        let result = RememberedSpeakerIdentification.apply(clusters: [first, second], utterances: [],
                                                           people: [person], voiceprints: [profile()])
        #expect(result.clusters.allSatisfy { $0.personId == person.id && $0.assignment == "auto" })
    }
}


extension RememberedSpeakerIdentificationTests {
    @Test func acousticLabelsReachUtterancesWithoutRememberedIdentity() {
        let input = cluster()
        let utterance = Utterance(id: 1, meetingId: input.meetingId, clusterId: input.id,
            speakerName: input.id, start: 0, end: 2, text: "Synthetic words")
        let result = RememberedSpeakerIdentification.apply(clusters: [input], utterances: [utterance], people: [], voiceprints: [])
        #expect(result.utterances.first?.speakerName == "Speaker 1")
        #expect(result.clusters.first?.personId == nil)
        #expect(result.clusters.first?.assignment == input.assignment)
    }

    @Test func alreadyConfirmedInputPropagatesItsNameToFreshUtterances() {
        var input = cluster(); input.assignment = "user"; input.label = "Confirmed person"; input.personId = person.id
        let utterance = Utterance(id: 1, meetingId: input.meetingId, clusterId: input.id,
            speakerName: input.id, start: 0, end: 2, text: "Synthetic words")
        let result = RememberedSpeakerIdentification.apply(clusters: [input], utterances: [utterance], people: [], voiceprints: [])
        #expect(result.utterances.first?.speakerName == "Confirmed person")
        #expect(result.clusters.first?.assignment == "user")
    }
}
