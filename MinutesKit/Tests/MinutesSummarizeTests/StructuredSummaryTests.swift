import Foundation
import Testing
import MinutesCore
@testable import MinutesSummarize

private actor OutcomeFixtureProvider: LLMProvider {
    nonisolated let id = "outcome-fixture"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_000
    func generate(system: String, prompt: String) async throws -> String {
        let ids = SummaryEvidence.suppliedIDs(in: prompt)
        if system.hasPrefix("Extract explicit outcomes.") {
            guard prompt.contains("LAUNCH_DECISION") || ids.contains("T0013") else { return "" }
            return "- Decision: Launch moves to May [\(ids[0])]\n- Action: Priya drafts the launch plan [\(ids[0])]\n- Action: Invented task for someone [T9999]\n- Action: Yeah [\(ids[0])]\n- Decision: Do we want separate newsletters for each city? [\(ids[0])]"
        }
        if prompt.contains("draft_summary") { return "- Condensed planning [\(ids[0])]." }
        return "- Point \(ids[0]) [\(ids[0])]."
    }
}

struct StructuredSummaryTests {
    private func discussion() -> [Utterance] {
        (0..<20).map { index in
            Utterance(id: index + 1, meetingId: "m", clusterId: "c", speakerName: "Speaker 1", start: Double(index * 60), end: Double(index * 60 + 50),
                      text: (index == 12 ? "LAUNCH_DECISION: we agreed to move the beacon launch to May. " : "We reviewed beacon planning item \(index + 1). ")
                        + String(repeating: "Supporting discussion about the beacon pilot and its constraints. ", count: 4))
        }
    }

    @Test("Long meetings get an overview, cited outcomes and timed discussion sections")
    func structuredLongMeeting() async throws {
        let summary = try await Summarizer(provider: OutcomeFixtureProvider()).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: discussion(), attendees: [])
        let md = summary.markdown
        #expect(md.contains("### Overview"))
        #expect(md.contains("### Decisions\n- Launch moves to May ["))
        #expect(md.contains("### Action items\n- Priya drafts the launch plan ["))
        #expect(!md.contains("Invented task") && !md.contains("Yeah") && !md.contains("separate newsletters"))
        #expect(md.contains("### Discussion"))
        let headings = md.components(separatedBy: "\n").filter { $0.hasPrefix("#### ") }
        #expect((2...8).contains(headings.count))
        #expect(headings.first?.hasPrefix("#### 0:00–") == true)
    }

    @Test("A short meeting keeps the plain bullet layout")
    func shortMeetingUnchanged() async throws {
        let utterances = [Utterance(id: 1, meetingId: "m", clusterId: "c", speakerName: "Speaker 1", start: 0, end: 30,
                                    text: "We reviewed the beacon pilot budget and the volunteer schedule for next month in detail today.")]
        let summary = try await Summarizer(provider: OutcomeFixtureProvider()).summarize(
            meeting: Meeting(id: "m", title: "Planning"), utterances: utterances, attendees: [])
        #expect(!summary.markdown.contains("### "))
    }
}
