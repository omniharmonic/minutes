import Foundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
@testable import MinutesApp

@MainActor
struct TranscriptSpeakerFlowTests {
    @Test("Fresh processing persists readable acoustic or strongly remembered names", arguments: [false, true])
    func freshNamesPersist(remembered: Bool) async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let meeting = Meeting(id: "meeting", title: "Fixture", audioPath: "/unused-injected-fixture.wav")
        try store.saveMeeting(meeting)
        let person = Person(id: "p", displayName: "Known fixture person")
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        if remembered {
            try store.savePerson(person)
            try store.saveVoiceprint(Voiceprint(personId: person.id, model: SpeakerEmbeddingModel.trainedID, vector: vector, speechSeconds: 30))
        }
        let cluster = SpeakerCluster(id: "c_meeting_1", meetingId: meeting.id, trackId: "t", label: "Speaker 1",
            centroid: vector, speechSeconds: 12, assignment: "unassigned", embeddingModel: SpeakerEmbeddingModel.trainedID)
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: cluster.id, speakerName: cluster.id,
            start: 0, end: 2, text: "Synthetic fixture words")
        let state = try AppState(store: store, processAudio: { id, _, _ in
            PipelineResult(meetingId: id, audioDuration: 12, sampleRate: 16000, words: [], segments: [], clusters: [cluster], utterances: [utterance], speechDuration: 12)
        })
        state.selectMeeting(id: meeting.id)
        await state.processCurrentMeeting()
        let expectedName = remembered ? person.displayName : "Speaker 1"
        #expect(store.listUtterances(meetingId: meeting.id).first?.speakerName == expectedName)
        #expect(state.currentUtterances.first?.speakerName == expectedName)
        let reloaded = try AppState(store: store)
        reloaded.selectMeeting(id: meeting.id)
        #expect(reloaded.currentUtterances.first?.speakerName == expectedName)
        #expect(store.listSpeakerClusters(meetingId: meeting.id).first?.personId == (remembered ? person.id : nil))
    }

    @Test("Loading legacy names projects raw IDs without writing over per-utterance edits")
    func legacyDisplayPreservesEdits() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        try store.saveMeeting(Meeting(id: "m", title: "Fixture"))
        let cluster = SpeakerCluster(id: "c_m_1", meetingId: "m", trackId: "t", label: "Confirmed fixture name", assignment: "user")
        try store.saveSpeakerClusters([cluster])
        let inputs = ["Confirmed fixture name", "Speaker 2", cluster.id].enumerated().map { index, name in
            Utterance(id: index, meetingId: "m", clusterId: cluster.id, speakerName: name, start: Double(index), end: Double(index + 1), text: "Synthetic")
        }
        try store.saveUtterances(inputs)
        let state = try AppState(store: store)
        state.selectMeeting(id: "m")
        #expect(state.currentUtterances.map(\.speakerName) == ["Confirmed fixture name", "Speaker 2", "Confirmed fixture name"])
        #expect(store.listUtterances(meetingId: "m").map(\.speakerName) == inputs.map(\.speakerName))
    }
}
