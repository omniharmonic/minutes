import Foundation
import Testing
import MinutesCore
@testable import MinutesSpeakerID

struct SpeakerAssignmentTests {
    private func fixture(speechSeconds: Double = 25, trained: Bool = true) throws -> MinutesStore {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "m", title: "Fixture"))
        try store.saveSpeakerClusters([
            SpeakerCluster(id: "c1", meetingId: "m", trackId: "t", label: "Speaker 1", centroid: [3] + Array(repeating: 0, count: 255),
                           speechSeconds: speechSeconds, confidence: 0.4, embeddingModel: trained ? SpeakerEmbeddingModel.trainedID : nil),
            SpeakerCluster(id: "c2", meetingId: "m", trackId: "t", label: "Speaker 2")
        ])
        try store.saveUtterances([
            Utterance(id: 1, meetingId: "m", clusterId: "c1", speakerName: "c1", start: 0, end: 1, text: "Synthetic one"),
            Utterance(id: 2, meetingId: "m", clusterId: "c2", speakerName: "", start: 1, end: 2, text: "Synthetic two"),
            Utterance(id: 3, meetingId: "m", clusterId: "c1", speakerName: "Speaker 1", start: 2, end: 3, text: "Synthetic three")
        ])
        return store
    }

    @Test("Naming creates the person, assigns the cluster and renames only its lines")
    func assignsByName() throws {
        let store = try fixture()
        let outcome = try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c1", displayName: "Ana Fixture", email: "ana@example.com", learn: false)
        #expect(outcome.person.displayName == "Ana Fixture")
        #expect(outcome.person.emails == ["ana@example.com"])
        #expect(outcome.voiceprint == nil)
        let cluster = try #require(store.listSpeakerClusters(meetingId: "m").first { $0.id == "c1" })
        #expect(cluster.label == "Ana Fixture" && cluster.personId == outcome.person.id && cluster.assignment == "user")
        #expect(cluster.confidence == 0.4) // The review screen never persisted a confidence change either.
        #expect(store.listUtterances(meetingId: "m").map(\.speakerName) == ["Ana Fixture", "Speaker 2", "Ana Fixture"])
        #expect(store.listVoiceprints().isEmpty)
    }

    @Test("An existing person is reused by email, else by name")
    func reusesPeople() throws {
        let store = try fixture()
        try store.savePerson(Person(id: "p-email", displayName: "Ana From Calendar", emails: ["ana@example.com"]))
        try store.savePerson(Person(id: "p-name", displayName: "Bo"))
        #expect(try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c1", displayName: "Ana", email: "ANA@example.com", learn: false).person.id == "p-email")
        #expect(try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c2", displayName: "bo", email: nil, learn: false).person.id == "p-name")
        #expect(store.listPeople().count == 2)
    }

    @Test("learn remembers a normalized voice; an ineligible cluster changes nothing")
    func learning() throws {
        let store = try fixture()
        let outcome = try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c1", displayName: "Ana", email: nil, learn: true)
        let voice = try #require(outcome.voiceprint)
        #expect(voice.personId == outcome.person.id)
        #expect(voice.vector.first == 1)
        #expect(store.listVoiceprints().count == 1)
        // Learning the same sample again does not duplicate the voice.
        _ = try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c1", displayName: "Ana", email: nil, learn: true)
        #expect(store.listVoiceprints().count == 1)

        let short = try fixture(speechSeconds: 5)
        #expect(throws: SpeakerAssignmentError.cannotLearn) {
            try SpeakerAssignment.assign(store: short, meetingID: "m", clusterID: "c1", displayName: "Ana", email: nil, learn: true)
        }
        #expect(short.listPeople().isEmpty)
        #expect(short.listSpeakerClusters(meetingId: "m").first { $0.id == "c1" }?.assignment == "suggested")
        let untrained = try fixture(trained: false)
        #expect(throws: SpeakerAssignmentError.cannotLearn) {
            try SpeakerAssignment.assign(store: untrained, meetingID: "m", clusterID: "c1", displayName: "Ana", email: nil, learn: true)
        }
    }

    @Test("Missing meetings, clusters and blank names are errors")
    func errors() throws {
        let store = try fixture()
        #expect(throws: SpeakerAssignmentError.meetingNotFound("x")) { try SpeakerAssignment.assign(store: store, meetingID: "x", clusterID: "c1", displayName: "A", email: nil, learn: false) }
        #expect(throws: SpeakerAssignmentError.clusterNotFound("zz")) { try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "zz", displayName: "A", email: nil, learn: false) }
        #expect(throws: SpeakerAssignmentError.emptyName) { try SpeakerAssignment.assign(store: store, meetingID: "m", clusterID: "c1", displayName: "  ", email: nil, learn: false) }
        #expect(store.listSpeakerClusters(meetingId: "m").first { $0.id == "c1" }?.label == "Speaker 1")
    }

    @Test("Unknown and single-line renames match the review screen")
    func unknownAndSingleLine() throws {
        let store = try fixture()
        try SpeakerAssignment.renameUtterance(store: store, meetingID: "m", utteranceID: 3, name: "Guest")
        #expect(store.listUtterances(meetingId: "m").map(\.speakerName) == ["c1", "", "Guest"])
        try SpeakerAssignment.keepUnknown(store: store, meetingID: "m", clusterID: "c1")
        let cluster = try #require(store.listSpeakerClusters(meetingId: "m").first { $0.id == "c1" })
        #expect(cluster.label == "Unknown speaker" && cluster.personId == nil && cluster.assignment == "unknown" && cluster.confidence == 0)
        #expect(store.listUtterances(meetingId: "m").map(\.speakerName) == ["Unknown speaker", "Speaker 2", "Unknown speaker"])
    }
}
