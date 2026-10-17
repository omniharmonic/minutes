import Testing
@testable import MinutesCore

struct LiveCaptionHistoryTests {
    @Test func revisionsReplaceTailAndFinalCannotRegress() {
        var history = LiveCaptionHistory()
        history.update(id: "a", text: "budget", source: "Mac audio", isFinal: false)
        history.update(id: "a", text: "budget approved", source: "Mac audio", isFinal: true)
        history.update(id: "a", text: "late stale partial", source: "Mac audio", isFinal: false)
        #expect(history.lines.count == 1)
        #expect(history.lines[0].text == "budget approved")
    }
    @Test func boundedHistoryAndStop() {
        var history = LiveCaptionHistory(limit: 2)
        for n in 0..<10 { history.update(id: String(n), text: "Text \(n)", source: "Fixture", isFinal: false) }
        #expect(history.lines.map(\.id) == ["8", "9"])
        history.finish()
        #expect(history.lines.allSatisfy { $0.isFinal })
    }
    @Test func emptyAndOversizedPartials() {
        var history = LiveCaptionHistory()
        history.update(id: "a", text: "  \n", source: "Fixture", isFinal: false)
        #expect(history.lines.isEmpty)
        history.update(id: "a", text: String(repeating: "a", count: 5000), source: "Fixture", isFinal: false)
        #expect(history.lines[0].text.count == 4000)
    }
}

@Test func provisionalNamesSurviveTextUpdatesWithoutRecreatingEvictedLines() {
    var history = LiveCaptionHistory(limit: 1)
    history.update(id: "first", text: "Partial", source: "Mac audio", isFinal: false)
    history.identify(id: "first", name: "Synthetic person")
    history.update(id: "first", text: "Final words", source: "Mac audio", isFinal: true)
    #expect(history.lines.first?.speakerName == "Synthetic person")
    history.update(id: "second", text: "Next", source: "Mac audio", isFinal: false)
    history.identify(id: "first", name: "Late result")
    #expect(history.lines.count == 1)
    #expect(history.lines.first?.speakerName == nil)
}

@Test func lateFinalWordsKeepChronologicalOrderAcrossRecognitionHandoffs() {
    var history = LiveCaptionHistory()
    history.update(id: "new", text: "Next speaker", source: "Mac audio", isFinal: false, order: 4)
    history.update(id: "old-tail", text: "Previous speaker's last words", source: "Mac audio", isFinal: true, order: 3)
    #expect(history.lines.map(\.id) == ["old-tail", "new"])
    history.update(id: "new", text: "", source: "Mac audio", isFinal: false, order: 4)
    #expect(history.lines.map(\.id) == ["old-tail"])
}
