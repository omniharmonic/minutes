import Foundation
import Testing
import MinutesCore
@testable import MinutesSummarize

/// Declines any request whose prompt contains `marker`, like Apple's model
/// refusing one 2 KB chunk of an otherwise ordinary 37-minute call.
private actor DecliningProvider: LLMProvider {
    nonisolated let id = "declining-fixture"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_000
    let marker: String
    let declineReductions: Bool
    init(marker: String, declineReductions: Bool = false) { self.marker = marker; self.declineReductions = declineReductions }
    func generate(system: String, prompt: String) async throws -> String {
        let records = prompt.components(separatedBy: "\n").compactMap { line -> [String: String]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        }.filter { $0["kind"] != "meeting_title" }
        let reducing = records.contains { $0["kind"] == "draft_summary" }
        if prompt.contains(marker), reducing == declineReductions { throw LocalSummaryProviderError.contentDeclined }
        if reducing { return "- Condensed planning [\(records[0]["id"]!)]." }
        return records.map { "- Point \($0["id"]!) \(prompt.contains(marker) ? marker : "") [\($0["id"]!)]." }.joined(separator: "\n")
    }
}

private struct BusyProvider: LLMProvider {
    let id = "busy-fixture"
    let isLocal = true
    var error = LocalSummaryProviderError.busy
    func generate(system: String, prompt: String) async throws -> String { throw error }
}

private func discussion(count: Int = 20, marked: Set<Int>) -> [Utterance] {
    (0..<count).map { index in
        let text = (marked.contains(index) ? "DECLINE_ME " : "") + "We reviewed planning item \(index + 1)."
            + String(repeating: " Supporting discussion about the current work and its constraints.", count: 5)
        return Utterance(id: index + 1, meetingId: "m", clusterId: "c", speakerName: "Unknown",
                         start: Double(index * 10), end: Double(index * 10 + 9), text: text)
    }
}

struct DeclinedChunkSummaryTests {
    @Test("One declined transcript chunk is skipped and disclosed instead of failing the summary")
    func firstPassDeclineIsDisclosed() async throws {
        let summary = try await Summarizer(provider: DecliningProvider(marker: "DECLINE_ME")).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: [3]), attendees: [])
        #expect(summary.markdown.contains("On-device AI draft"))
        #expect(summary.markdown.contains("could not be summarized by the model"))
    }

    @Test("When most chunks are declined, the remaining notes are saved with the gap disclosed")
    func majorityDeclineIsDisclosed() async throws {
        let summary = try await Summarizer(provider: DecliningProvider(marker: "DECLINE_ME")).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: Set(0..<15)), attendees: [])
        #expect(Summarizer.isGeneratedDraft(summary))
        #expect(summary.markdown.contains("could not be summarized by the model"))
    }

    @Test("When every chunk is declined, labeled transcript highlights are saved instead of failing")
    func totalDeclineSavesLabeledHighlights() async throws {
        let summary = try await Summarizer(provider: DecliningProvider(marker: "DECLINE_ME")).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: Set(0..<20)), attendees: [])
        #expect(!Summarizer.isGeneratedDraft(summary))
        #expect(summary.markdown.contains("## Transcript highlights"))
        #expect(summary.markdown.contains("could not write notes for this meeting"))
    }

    @Test("A busy model still fails the attempt so the summary is retried later")
    func busyModelIsNotReplacedWithHighlights() async {
        await #expect(throws: LocalSummaryProviderError.self) {
            try await Summarizer(provider: BusyProvider()).summarize(
                meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: []), attendees: [])
        }
    }

    @Test("An unavailable model saves labeled highlights")
    func unavailableModelSavesHighlights() async throws {
        let summary = try await Summarizer(provider: BusyProvider(error: .unavailable(.appleIntelligenceDisabled))).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: []), attendees: [])
        #expect(summary.markdown.contains("could not write notes for this meeting"))
    }

    @Test("A declined reduction carries its validated notes forward and the summary still completes")
    func reductionDeclineCarriesNotesForward() async throws {
        let summary = try await Summarizer(provider: DecliningProvider(marker: "DECLINE_ME", declineReductions: true)).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: [3]), attendees: [])
        #expect(summary.markdown.contains("On-device AI draft"))
        #expect(summary.overview.contains("DECLINE_ME"))
        #expect(!summary.markdown.contains("could not be summarized"))
    }
}
