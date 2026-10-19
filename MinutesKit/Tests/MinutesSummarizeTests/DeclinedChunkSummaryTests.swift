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

    @Test("When most chunks are declined, the summary fails rather than claiming coverage")
    func majorityDeclineFails() async {
        await #expect(throws: LocalSummaryProviderError.self) {
            try await Summarizer(provider: DecliningProvider(marker: "DECLINE_ME")).summarize(
                meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(marked: Set(0..<15)), attendees: [])
        }
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
