import Foundation
import Testing
import MinutesCore
import MinutesSummarize

private struct ConciseFixtureProvider: LLMProvider {
    let id = "concise-local-fixture"
    let isLocal = true
    func generate(system: String, prompt: String) async throws -> String {
        "- Telescope calibration is planned for Tuesday. [T0001]"
    }
}
struct SummaryPresentationTests {
    private let speech = Utterance(id: 1, meetingId: "concise", clusterId: "c", speakerName: "Speaker 1",
        start: 0, end: 2, text: "Telescope calibration is planned for Tuesday.")
    @Test func generatedSummaryIsPrimaryAndDoesNotRepeatTranscriptOrClaimExtractiveMode() async throws {
        let result = try await Summarizer(provider: ConciseFixtureProvider()).summarize(
            meeting: Meeting(id: "concise", title: "Telescope calibration"), utterances: [speech], attendees: [])
        #expect(!result.markdown.contains("Extractive notes"))
        #expect(!result.markdown.contains("## Transcript"))
        #expect(!result.markdown.contains("## Discussion Topics"))
        #expect(result.markdown.components(separatedBy: speech.text).count == 2)
        #expect(result.overview.contains("[T0001]"))
    }
    @Test func extractiveHighlightsAreLabeledAndDoNotRepeatTheWholeTranscript() async throws {
        let result = try await Summarizer().summarize(meeting: Meeting(id: "concise", title: "Telescope calibration"),
                                                   utterances: [speech, speech], attendees: [])
        #expect(result.markdown.contains("No AI summary"))
        #expect(!result.markdown.contains("## Transcript\n"))
        #expect(result.markdown.components(separatedBy: speech.text).count == 2)
        #expect(!result.markdown.contains("## Potential decisions"))
    }
}

extension SummaryPresentationTests {
    @Test func freshEligibleDevicesUseAIAndExplicitChoicesAlwaysWin() {
        #expect(FoundationModelsProvider.initialPreference(savedChoice: nil, availability: .available))
        #expect(!FoundationModelsProvider.initialPreference(savedChoice: nil, availability: .modelNotReady))
        #expect(!FoundationModelsProvider.initialPreference(savedChoice: nil, availability: .requiresNewerOS))
        #expect(!FoundationModelsProvider.initialPreference(savedChoice: false, availability: .available))
        #expect(FoundationModelsProvider.initialPreference(savedChoice: true, availability: .unavailable))
    }
}
