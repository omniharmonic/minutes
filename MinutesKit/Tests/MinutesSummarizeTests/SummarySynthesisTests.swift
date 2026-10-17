import Foundation
import Testing
import MinutesCore
@testable import MinutesSummarize

private actor FictionalQualityProvider: LLMProvider {
    nonisolated let id = "fictional-native-quality"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_800
    func generate(system: String, prompt: String) async throws -> String {
        let result = try await FoundationModelsProvider().generate(system: system, prompt: prompt)
        print("FICTIONAL_QUALITY_STAGE: \(result)")
        return result
    }
}

private actor SynthesisFixtureProvider: LLMProvider {
    nonisolated let id = "bounded-synthesis-fixture"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_000
    private(set) var requests: [(String, String)] = []
    let corruptReduction: Bool
    init(corruptReduction: Bool = false) { self.corruptReduction = corruptReduction }
    func generate(system: String, prompt: String) async throws -> String {
        requests.append((system, prompt))
        let records = prompt.components(separatedBy: "\n").compactMap { line -> [String: String]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        }.filter { $0["kind"] != "meeting_title" }
        if records.contains(where: { $0["kind"] == "draft_summary" }) {
            if corruptReduction { return "- The launch is approved [T9999]." }
            if let decision = records.first(where: { $0["text"]?.contains("CANCELLED_RELEASE") == true }) {
                return "- CANCELLED_RELEASE: The release remains cancelled pending the safety review [\(decision["id"]!)]."
            }
            return "- Other planning context [\(records[0]["id"]!)]."
        }
        return records.map { record in
            let text = record["text"]!.contains("CANCELLED_RELEASE") ? "CANCELLED_RELEASE: Release cancelled pending safety review" : "Planning detail \(record["id"]!)"
            return "- \(text) [\(record["id"]!)]."
        }.joined(separator: "\n")
    }
    func recorded() -> [(String, String)] { requests }
}

struct SummarySynthesisTests {
    @Test("Open questions must quote an actual excerpt from their cited source")
    func questionsCannotInventUncertainty() {
        let source = #"{"id":"T0003","kind":"transcript","text":"We still need to know whether the bank sandbox supports partial refunds. Nobody has committed to an earlier launch."}"#
        #expect(SummaryQuestionEvidence.supports(excerpt: "We still need to know whether the bank sandbox supports partial refunds.", ids: ["T0003"], prompt: source))
        #expect(!SummaryQuestionEvidence.supports(excerpt: "Has anyone committed to an earlier launch?", ids: ["T0003"], prompt: source))
        #expect(!SummaryQuestionEvidence.supports(excerpt: "We still need to know whether the bank sandbox supports partial refunds.", ids: ["T0001"], prompt: source))
        let draft = #"{"id":"T0001","additionalIDs":"T0002 T0003","kind":"draft_summary","text":"We still need to know whether the bank sandbox supports partial refunds."}"#
        #expect(SummaryQuestionEvidence.supports(excerpt: "We still need to know whether the bank sandbox supports partial refunds.", ids: ["T0003"], prompt: draft))
    }
    @Test func explicitUnknownsRemainSourceExcerptsWithoutInventedQuestions() {
        let prompt = #"{"id":"T0003","kind":"transcript","text":"We still need to know whether the bank sandbox supports partial refunds. Nobody has committed to an earlier launch. Priya will ask the bank on Monday."}"#
        let excerpts = SummaryQuestionEvidence.unansweredExcerpts(prompt: prompt)
        #expect(excerpts.count == 1)
        #expect(excerpts.first?.text == "We still need to know whether the bank sandbox supports partial refunds.")
        #expect(excerpts.first?.id == "T0003")
        let draft = #"{"id":"T0001","additionalIDs":"T0003 T0004","kind":"draft_summary","text":"We still need to know whether the bank supports partial refunds."}"#
        #expect(SummaryQuestionEvidence.unansweredExcerpts(prompt: draft).first?.evidenceIDs == ["T0001", "T0003", "T0004"])
        #expect(SummaryQuestionEvidence.unansweredExcerpts(prompt: #"{"id":"T0001","kind":"transcript","text":"Nobody has committed to an earlier launch. The decision is not approved."}"#).isEmpty)
        #expect(SummaryQuestionEvidence.unansweredExcerpts(prompt: #"{"id":"N0001","kind":"user_notes","text":"We still need to know whether the bank supports refunds."}"#).isEmpty)
    }
    private func discussion() -> [Utterance] {
        (0..<20).map { index in
            let content = index == 7 ? "CANCELLED_RELEASE: We cancelled the release pending a safety review." : "We reviewed planning item \(index + 1)."
            return Utterance(id: index + 1, meetingId: "synthesis", clusterId: "c", speakerName: "Unknown", start: Double(index * 10), end: Double(index * 10 + 9), text: content + String(repeating: " Supporting discussion about the current work and its constraints.", count: 5))
        }
    }
    @Test("Whole-meeting synthesis preserves a middle decision instead of uniformly sampling eight draft lines")
    func synthesizesInsteadOfDroppingMiddleFacts() async throws {
        let provider = SynthesisFixtureProvider()
        let summary = try await Summarizer(provider: provider).summarize(meeting: Meeting(id: "synthesis", title: "Release readiness"), utterances: discussion(), attendees: [])
        let requests = await provider.recorded()
        #expect(requests.contains { $0.1.contains("\"kind\":\"draft_summary\"") })
        #expect(summary.overview.contains("CANCELLED_RELEASE"))
        #expect(summary.overview.contains("[T0008]"))
        #expect(requests.allSatisfy { $0.0.utf8.count + $0.1.utf8.count <= 2_000 })
    }
    @Test("Synthesis cannot introduce references absent from its input facts")
    func validatesReductionEvidence() async throws {
        let provider = SynthesisFixtureProvider(corruptReduction: true)
        await #expect(throws: SummaryError.self) {
            try await Summarizer(provider: provider).summarize(meeting: Meeting(id: "synthesis", title: "Release readiness"), utterances: discussion(), attendees: [])
        }
    }
    @Test("Negated decisions and actions never become affirmative structured outcomes")
    func negativeIntentDoesNotBecomeCommitment() async throws {
        let lines = ["We have not decided whether to launch.", "We have not agreed on the date.", "I will not approve the release.", "There is no action required."]
        let speech = lines.enumerated().map { Utterance(id: $0.offset + 1, meetingId: "negative", clusterId: "c", speakerName: "Unknown", start: Double($0.offset), end: Double($0.offset + 1), text: $0.element) }
        let summary = try await Summarizer().summarize(meeting: Meeting(id: "negative", title: "Unresolved release"), utterances: speech, attendees: [])
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems.isEmpty)
    }
}

@Suite("Fictional native summary quality acceptance", .serialized)
struct NativeSummaryQualityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_SUMMARY_QUALITY"] == "1"))
    func tinyMeaningfulClipProducesOneUsefulPoint() async throws {
        guard FoundationModelsProvider.availability() == .available else { return }
        let speech = Utterance(id: 1, meetingId: "brief-quality", clusterId: "c", speakerName: "Unknown", start: 0, end: 7,
            text: "Keep the old report until Monday. The new export still drops refunds.")
        let result = try await Summarizer(provider: FoundationModelsProvider()).summarize(meeting: Meeting(id: "brief-quality", title: "Fictional report check"), utterances: [speech], attendees: [])
        let bullets = result.overview.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(bullets.count == 1)
        #expect(result.overview.localizedCaseInsensitiveContains("refund"))
        #expect(result.overview.localizedCaseInsensitiveContains("Monday") || result.overview.localizedCaseInsensitiveContains("old report"))
        #expect(!result.overview.localizedCaseInsensitiveContains("participants discussed"))
        #expect(result.overview.split(whereSeparator: \.isWhitespace).count <= 35)
        print("FICTIONAL_BRIEF_QUALITY: \(result.overview)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_SUMMARY_QUALITY"] == "1"))
    func meaningfulDiscussionPreservesOutcomeAndConcreteNextSteps() async throws {
        guard FoundationModelsProvider.availability() == .available else { return }
        let lines = [
            "The fictional Harbor release was planned for Friday, but the refund export still loses partial refunds. We agreed to move the release to Tuesday because finance cannot reconcile missing rows. Friday is no longer an approved launch date. The existing report stays in use until the replacement passes those checks.",
            "Maya will fix the refund export by Monday noon. Leo will rerun the three blocked refund cases on Monday afternoon and send the actual results to finance. Failed checks must not be counted as complete. We are not adding new dashboard features to this release; the refund defect is the priority.",
            "Tuesday remains conditional on all three refund cases passing. If they still fail, we postpone again instead of accepting missing data. We still need to know whether the bank sandbox supports partial refunds. Priya will ask the bank and bring its answer on Monday. Nobody has committed to an earlier launch or an additional feature."
        ]
        let speech = lines.enumerated().map { Utterance(id: $0.offset + 1, meetingId: "discussion-quality", clusterId: "c", speakerName: "Unknown", start: Double($0.offset * 30), end: Double($0.offset * 30 + 29), text: $0.element) }
        let result = try await Summarizer(provider: FictionalQualityProvider()).summarize(meeting: Meeting(id: "discussion-quality", title: "Fictional release readiness"), utterances: speech, attendees: [])
        #expect(result.overview.localizedCaseInsensitiveContains("Tuesday"))
        #expect(result.overview.localizedCaseInsensitiveContains("refund"))
        #expect(result.overview.localizedCaseInsensitiveContains("Maya"))
        #expect(result.overview.localizedCaseInsensitiveContains("Leo"))
        #expect(result.overview.localizedCaseInsensitiveContains("Monday"))
        #expect(result.overview.localizedCaseInsensitiveContains("conditional") || result.overview.localizedCaseInsensitiveContains("all three"))
        #expect(result.overview.localizedCaseInsensitiveContains("bank"))
        #expect(result.overview.localizedCaseInsensitiveContains("Priya"))
        #expect(result.overview.localizedCaseInsensitiveContains("sandbox") || result.overview.localizedCaseInsensitiveContains("supports partial refunds"))
        #expect(!result.overview.components(separatedBy: "\n").contains { $0.contains("?") && ($0.localizedCaseInsensitiveContains("earlier launch") || $0.localizedCaseInsensitiveContains("additional feature")) })
        #expect(!result.overview.localizedCaseInsensitiveContains("participants discussed"))
        #expect(!result.overview.localizedCaseInsensitiveContains("microphone"))
        #expect(result.markdown.contains("Generated notes"))
        print("FICTIONAL_DISCUSSION_QUALITY: \(result.overview)")
    }
}
