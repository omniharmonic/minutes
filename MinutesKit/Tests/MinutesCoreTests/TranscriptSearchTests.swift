import Foundation
import Testing
@testable import MinutesCore

struct TranscriptSearchTests {
    private func line(_ id: Int, _ text: String, speaker: String = "Ana") -> Utterance {
        Utterance(id: id, meetingId: "search-fixture", clusterId: "speaker", speakerName: speaker, start: Double(id), end: Double(id + 1), text: text)
    }

    @Test func occurrencesStayInTranscriptOrderAndWrap() {
        let matches = TranscriptSearch.matches(in: [line(1, "Budget, budget!"), line(2, "BUDGET approved")], query: " budget \n")
        #expect(matches.map(\.utteranceID) == [1, 1, 2])
        #expect(Set(matches.map(\.id)).count == 3)
        #expect(TranscriptSearch.advancedIndex(2, by: 1, count: 3) == 0)
        #expect(TranscriptSearch.advancedIndex(0, by: -1, count: 3) == 2)
        #expect(TranscriptSearch.advancedIndex(0, by: 1, count: 0) == 0)
    }

    @Test func accentsAndEmojiKeepValidHighlightRanges() throws {
        let text = "👩🏽‍💻 Café, cafe\u{301}, CAFÉ"
        let matches = TranscriptSearch.matches(in: [line(1, text)], query: "cafe")
        #expect(matches.count == 3)
        for match in matches {
            let range = try #require(Range(match.range, in: text))
            #expect(text[range].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == "cafe")
        }
    }

    @Test func literalSearchAndSpeakerNamesWithoutEmptyMatches() {
        #expect(TranscriptSearch.matches(in: [line(1, "hello")], query: " \n").isEmpty)
        #expect(TranscriptSearch.matches(in: [line(1, "hello")], query: "missing").isEmpty)
        let lines = [line(1, "[plan] approved", speaker: "José")]
        #expect(TranscriptSearch.matches(in: lines, query: "[plan]").count == 1)
        #expect(TranscriptSearch.matches(in: lines, query: "jose").first?.field == .speaker)
        #expect(TranscriptSearch.matches(in: [line(1, "revised")], query: "plan").isEmpty)
    }
}
