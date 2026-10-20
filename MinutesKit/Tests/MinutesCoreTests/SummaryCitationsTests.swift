import Foundation
import Testing
import MinutesCore

struct SummaryCitationsTests {
    private let utterances = [
        Utterance(id: 1, meetingId: "m", clusterId: "c", speakerName: "A", start: 4.2, end: 9, text: "Opening"),
        Utterance(id: 2, meetingId: "m", clusterId: "c", speakerName: "B", start: 724.9, end: 730, text: "Budget"),
        Utterance(id: 3, meetingId: "m", clusterId: "c", speakerName: "A", start: 3_725, end: 3_730, text: "Wrap"),
    ]

    @Test("Citations read as times in exports; notes and unknown ids are dropped")
    func readable() {
        let markdown = "- Budget agreed [T0002]\n- Wrap-up [T0003, T0001]\n- From notes [N0001]\n- Stale [T0099]"
        #expect(SummaryCitations.readableMarkdown(markdown, utterances: utterances)
            == "- Budget agreed (12:04)\n- Wrap-up (0:04, 1:02:05)\n- From notes\n- Stale")
    }

    @Test("Display links seek to the cited utterance and untimed imports show no times")
    func linked() throws {
        let linked = SummaryCitations.linkedMarkdown("Budget [T0002][T0002]", utterances: utterances)
        #expect(linked == "Budget [12:04](minutes-seek:724.900) [12:04](minutes-seek:724.900)" || linked == "Budget [12:04](minutes-seek:724.900)")
        let url = try #require(URL(string: "minutes-seek:724.900"))
        #expect(SummaryCitations.seconds(from: url) == 724.9)
        #expect(SummaryCitations.seconds(from: URL(string: "https://example.com")!) == nil)
        #expect(SummaryCitations.readableMarkdown("Point [T0001]", utterances: utterances, timed: false) == "Point")
    }
}
