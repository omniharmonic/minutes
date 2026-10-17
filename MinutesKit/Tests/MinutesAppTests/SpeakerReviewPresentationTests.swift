import Testing
import MinutesCore
import MinutesSpeakerID
@testable import MinutesUI

struct SpeakerReviewPresentationTests {
    @Test("Short speech stays in seconds; minutes retain their remaining seconds")
    func honestDuration() {
        #expect(SpeakerReviewPresentation.speechDuration(8.9) == "8 sec")
        #expect(SpeakerReviewPresentation.speechDuration(59.9) == "59 sec")
        #expect(SpeakerReviewPresentation.speechDuration(60) == "1 min")
        #expect(SpeakerReviewPresentation.speechDuration(65) == "1 min 5 sec")
        #expect(SpeakerReviewPresentation.speechDuration(0.5) == "Less than 1 sec")
        #expect(SpeakerReviewPresentation.speechDuration(.nan) == "Unknown duration")
    }

    @Test("Remember requires twenty seconds and a valid trained voice, independently of name confirmation")
    func minimumUsableVoice() {
        var cluster = SpeakerCluster(meetingId: "m", trackId: "t", label: "A", centroid: Array(repeating: 0.1, count: 256), speechSeconds: 8, assignment: "user", embeddingModel: SpeakerEmbeddingModel.trainedID)
        #expect(!SpeakerReviewPresentation.canRemember(cluster))
        #expect(SpeakerReviewPresentation.rememberExplanation(cluster).contains("at least 20 seconds"))
        #expect(SpeakerReviewPresentation.rememberExplanation(cluster).contains("still confirm their name"))
        cluster.speechSeconds = 19.99
        #expect(!SpeakerReviewPresentation.canRemember(cluster))
        cluster.speechSeconds = 20
        #expect(SpeakerReviewPresentation.canRemember(cluster))
        cluster.centroid[0] = .nan
        #expect(!SpeakerReviewPresentation.canRemember(cluster))
        cluster.centroid = Array(repeating: 0, count: 256)
        #expect(!SpeakerReviewPresentation.canRemember(cluster))
        cluster.centroid = Array(repeating: 0.1, count: 256)
        cluster.embeddingModel = "untrained"
        #expect(!SpeakerReviewPresentation.canRemember(cluster))
    }
}

extension SpeakerReviewPresentationTests {
    @Test("Older voice profiles need a new sample even when their speech duration is sufficient")
    func legacyProfileWarningDoesNotRelabelProvenance() {
        let vector = [Float](repeating: 0.1, count: 256)
        let legacy = Voiceprint(personId: "p", model: "wespeaker_v2", vector: vector, speechSeconds: 30)
        #expect(SpeakerReviewPresentation.profileWarning(legacy)?.contains("Older voice profile") == true)
        #expect(legacy.model == "wespeaker_v2")
        let current = Voiceprint(personId: "p", model: SpeakerEmbeddingModel.trainedID, vector: vector, speechSeconds: 30)
        #expect(SpeakerReviewPresentation.profileWarning(current) == nil)
    }
}

extension SpeakerReviewPresentationTests {
    @Test("Confirming an existing email preserves its person ID and manually saved name")
    func reuseExactEmailForSpeakerConfirmation() {
        let existing = Person(id: "saved-person", displayName: "Casey’s chosen name", isMe: true, emails: ["Casey@Example.test"])
        let result = SpeakerReviewPresentation.personForConfirmation(name: "Calendar spelling", email: "  CASEY@example.test  ", knownPeople: [existing])
        #expect(result.id == existing.id)
        #expect(result.displayName == existing.displayName)
        #expect(result.emails == existing.emails)
        #expect(result.isMe == existing.isMe)
    }

    @Test("A matching display name alone cannot merge speaker identities")
    func sameNameAndEmptyEmailDoNotMergePeople() {
        let existing = Person(id: "saved-person", displayName: "Casey Example", emails: ["casey@example.test"])
        let differentEmail = SpeakerReviewPresentation.personForConfirmation(name: existing.displayName, email: "other@example.test", knownPeople: [existing])
        #expect(differentEmail.id != existing.id)
        #expect(differentEmail.emails == ["other@example.test"])
        let noEmail = SpeakerReviewPresentation.personForConfirmation(name: existing.displayName, email: "  ", knownPeople: [existing])
        #expect(noEmail.id != existing.id)
        #expect(noEmail.emails.isEmpty)
    }
}
