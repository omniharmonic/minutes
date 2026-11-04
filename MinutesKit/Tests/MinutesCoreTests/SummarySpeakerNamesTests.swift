import Foundation
import Testing
@testable import MinutesCore

struct SummarySpeakerNamesTests {
    private func utterance(_ id: Int, _ cluster: String, _ name: String) -> Utterance {
        Utterance(id: id, meetingId: "m", clusterId: cluster, speakerName: name, start: Double(id), end: Double(id) + 1, text: "x")
    }

    @Test func namesReplaceGenericLabelsEverywhereButNotLookalikes() throws {
        let summary = MeetingSummary(meetingId: "m", title: "Sync", overview: "Speaker 1 and Speaker 10 disagreed.",
                                     decisions: ["Speaker 1 owns launch"], markdown: "- Speaker 1: ship (Speaker 10 objects)")
        let renames = SummarySpeakerNames.renames(before: [utterance(1, "c1", "Speaker 1"), utterance(2, "c10", "Speaker 10")],
                                                  after: [utterance(1, "c1", "Ana"), utterance(2, "c10", "Speaker 10")])
        #expect(renames == ["Speaker 1": "Ana"])
        let updated = try #require(SummarySpeakerNames.apply(renames, to: summary))
        #expect(updated.overview == "Ana and Speaker 10 disagreed.")
        #expect(updated.decisions == ["Ana owns launch"])
        #expect(updated.markdown == "- Ana: ship (Speaker 10 objects)")
        #expect(updated.meetingId == "m")
    }

    @Test func realNamesAreNeverRewrittenAndNoChangeMeansNil() {
        let summary = MeetingSummary(meetingId: "m", title: "Sync", overview: "Ana spoke.")
        #expect(SummarySpeakerNames.renames(before: [utterance(1, "c1", "Ana")], after: [utterance(1, "c1", "Bea")]).isEmpty)
        #expect(SummarySpeakerNames.apply(["Ana": "Bea"], to: summary) == nil)
        #expect(SummarySpeakerNames.apply(["Speaker 2": "Bea"], to: summary) == nil)
    }

    @Test func aLabelSplitBetweenTwoPeopleIsLeftAlone() {
        let renames = SummarySpeakerNames.renames(before: [utterance(1, "a", "Speaker 1"), utterance(2, "b", "Speaker 1")],
                                                  after: [utterance(1, "a", "Ana"), utterance(2, "b", "Bea")])
        #expect(renames.isEmpty)
    }
}
