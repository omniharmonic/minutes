import Foundation
import Testing
import MinutesCore
import MinutesSummarize

private actor FictionalAppleProbe: LLMProvider {
    nonisolated let id = "apple-foundation-models-on-device"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_800
    private var replies: [String] = []
    func generate(system: String, prompt: String) async throws -> String {
        let output = try await FoundationModelsProvider().generate(system: system, prompt: prompt)
        replies.append(output)
        return output
    }
    func outputs() -> [String] { replies }
}
struct ShortSpeechSummaryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_LOCAL_SUMMARY"] == "1"))
    func fictionalSelfIntroductionHasHonestInsufficientConversationResult() async throws {
        guard FoundationModelsProvider.availability() == .available else { return }
        let provider = FictionalAppleProbe()
        let meeting = Meeting(id: "fictional-casey-introduction", title: "Fictional microphone check")
        let speech = Utterance(id: 1, meetingId: meeting.id, clusterId: "c", speakerName: "Unknown", start: 0, end: 4,
                               text: "This is Casey speaking. My name is Casey Example.")
        do {
            let result = try await Summarizer(provider: provider).summarize(meeting: meeting, utterances: [speech], attendees: [])
            #expect(result.markdown.contains("[T0001]"))
            #expect(result.decisions.isEmpty && result.actionItems.isEmpty)
            #expect(result.overview.contains("not enough substantive conversation"))
            #expect(result.markdown.contains("No AI summary was generated"))
            #expect(await provider.outputs().isEmpty)
            print("FICTIONAL_CASEY_SUMMARY: \(result.overview)")
        } catch {
            print("FICTIONAL_CASEY_RAW_REPLIES: \(await provider.outputs())")
            throw error
        }
    }
}

private actor CitationRetryFixture: LLMProvider {
    nonisolated let id = "citation-retry-fixture"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 2_800
    private var replies: [String]
    private(set) var requests: [(String, String)] = []
    init(_ replies: [String]) { self.replies = replies }
    func generate(system: String, prompt: String) async throws -> String {
        requests.append((system, prompt))
        return replies.isEmpty ? "- Unsupported output [T9999]" : replies.removeFirst()
    }
    func recorded() -> [(String, String)] { requests }
}
struct BoundedCitationRetryTests {
    private let speech = Utterance(id: 1, meetingId: "retry", clusterId: "c", speakerName: "Unknown", start: 0, end: 4,
                                   text: "We plan to inspect the fictional telescope on Tuesday.")
    @Test func retriesOnceWithSameEvidenceAndExplicitIDsWithoutAddingCitations() async throws {
        let provider = CitationRetryFixture(["- Telescope inspection is planned for Tuesday.", "- Telescope inspection is planned for Tuesday. [T0001]"])
        let summary = try await Summarizer(provider: provider).summarize(meeting: Meeting(id: "retry", title: "Fictional introduction"), utterances: [speech], attendees: [])
        let requests = await provider.recorded()
        #expect(requests.count == 2)
        #expect(requests.first?.1 == requests.last?.1)
        #expect(requests.last?.0.contains("Allowed evidence IDs: T0001") == true)
        #expect(requests.first?.0.contains("Summary length: brief.") == true)
        #expect(requests.last?.0.contains("Summary length: brief.") == true)
        #expect(requests.allSatisfy { $0.0.utf8.count + $0.1.utf8.count <= provider.maximumInputBytes })
        #expect(summary.overview == "- Telescope inspection is planned for Tuesday. [T0001]")
    }
    @Test func secondUnsupportedResultIsNotSavedAndDoesNotRetryForever() async throws {
        let provider = CitationRetryFixture(["- Invented [T9999]", "- Still unsupported [T9999]"])
        let summary = try await Summarizer(provider: provider).summarize(meeting: Meeting(id: "retry", title: "Fictional introduction"), utterances: [speech], attendees: [])
        #expect(!Summarizer.isGeneratedDraft(summary))
        #expect(!summary.markdown.contains("Invented") && !summary.markdown.contains("Still unsupported"))
        #expect(await provider.recorded().count == 2)
    }
}

struct MeaningfulAppleSummaryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_LOCAL_SUMMARY"] == "1"))
    func fictionalGardenPlanProducesMergedUsefulPointsWithoutTestFiller() async throws {
        guard FoundationModelsProvider.availability() == .available else { return }
        let meeting = Meeting(id: "fictional-garden-plan", title: "Fictional garden planning")
        let lines = ["This is a microphone test. Hello, this is Casey speaking.",
                     "For our fictional neighborhood garden, we agreed to plant tomatoes on Saturday.",
                     "Casey will bring compost and Jordan will bring watering cans. We need to check Friday's weather before finalizing the watering plan."]
        let speech = lines.enumerated().map { Utterance(id: $0.offset + 1, meetingId: meeting.id, clusterId: "c", speakerName: "Unknown", start: Double($0.offset * 5), end: Double($0.offset * 5 + 4), text: $0.element) }
        let result = try await Summarizer(provider: FoundationModelsProvider()).summarize(meeting: meeting, utterances: speech, attendees: [])
        let bullets = result.overview.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect((1...3).contains(bullets.count))
        #expect(result.overview.localizedCaseInsensitiveContains("tomatoes"))
        #expect(result.overview.localizedCaseInsensitiveContains("compost"))
        #expect(result.overview.localizedCaseInsensitiveContains("weather"))
        #expect(!result.overview.localizedCaseInsensitiveContains("microphone"))
        #expect(!result.overview.localizedCaseInsensitiveContains("test"))
        print("FICTIONAL_GARDEN_SUMMARY: \(result.overview)")
    }
}

struct IntroOnlyAssessmentTests {
    @Test func doesNotDiscardDiscussionOrPersonalNotes() {
        func speech(_ text: String) -> [Utterance] { [Utterance(id: 1, meetingId: "fixture", clusterId: "", speakerName: "Unknown", start: 0, end: 1, text: text)] }
        #expect(Summarizer.hasOnlyIntroductions(utterances: speech("This is Casey speaking. My name is Casey Example.")))
        #expect(!Summarizer.hasOnlyIntroductions(utterances: speech("My name is Casey. We agreed to plant tomatoes on Saturday.")))
        #expect(!Summarizer.hasOnlyIntroductions(utterances: speech("My name is Casey and we need to delay the launch.")))
        #expect(!Summarizer.hasOnlyIntroductions(utterances: speech("This is Casey speaking about the garden.")))
        #expect(!Summarizer.hasOnlyIntroductions(utterances: speech("My name is Casey."), userNotes: "Discuss the launch schedule"))
    }
}
