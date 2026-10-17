import Testing
@testable import MinutesCore

struct TranscriptSpeakerLabelsTests {
    @Test("Legacy identifiers become cluster labels while explicit names and generic edits survive")
    func projectsOnlyIdentifiers() {
        let clusters = [SpeakerCluster(id: "c_first", meetingId: "m", trackId: "t", label: "Speaker 1"),
                        SpeakerCluster(id: "c_second", meetingId: "m", trackId: "t", label: "Speaker 2")]
        let names = ["Speaker 1", "Speaker 2", "c_second", ""]
        let inputs = names.enumerated().map { index, name in
            Utterance(id: index, meetingId: "m", clusterId: index < 2 ? "c_first" : "c_second", speakerName: name, start: Double(index), end: Double(index + 1), text: "Synthetic")
        }
        let output = TranscriptSpeakerLabels.readableUtterances(inputs, clusters: clusters)
        #expect(output.map(\.speakerName) == ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 2"])
        #expect(inputs[2].speakerName == "c_second")
        #expect(output.map(\.clusterId) == inputs.map(\.clusterId))
    }

    @Test("A different meeting's cluster cannot supply a name")
    func scopesLabelsToMeeting() {
        let cluster = SpeakerCluster(id: "c", meetingId: "other", trackId: "t", label: "Other person")
        let utterance = Utterance(id: 1, meetingId: "m", clusterId: "c", speakerName: "c", start: 0, end: 1, text: "Synthetic")
        #expect(TranscriptSpeakerLabels.readableUtterances([utterance], clusters: [cluster]).first?.speakerName == "Speaker 1")
    }
}
