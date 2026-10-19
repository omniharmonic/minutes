import Foundation
import Testing
import MinutesCore
import MinutesSummarize

private actor RecordingSummaryProvider: LLMProvider {
    nonisolated let id = "fixture"
    nonisolated let isLocal = true
    nonisolated let maximumInputBytes = 1_800
    private(set) var requests: [(String, String)] = []
    func generate(system: String, prompt: String) async throws -> String {
        requests.append((system, prompt))
        let expression = try NSRegularExpression(pattern: #""id":"([TN][0-9]+)""#)
        let match = expression.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))!
        let identifier = String(prompt[Range(match.range(at: 1), in: prompt)!])
        return "- Review the supplied evidence [\(identifier)]."
    }
    func recorded() -> [(String, String)] { requests }
}

@Suite("Bounded local summary evidence without model inference")
struct LocalSummaryProviderTests {
    @Test("The provider receives actual source timing and separately labeled personal notes")
    func timestampedEvidence() async throws {
        let provider = RecordingSummaryProvider()
        let meeting = Meeting(id: "evidence", title: "Planning", userNotes: "My private hypothesis, not a decision")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: "c", speakerName: "Speaker 1", start: 65.25, end: 69.75, text: "We could revisit the date.")
        let summary = try await Summarizer(provider: provider).summarize(meeting: meeting, utterances: [utterance], attendees: [])
        let requests = await provider.recorded()
        #expect(requests.contains { $0.1.contains("01:05.250") && $0.1.contains("01:09.750") })
        #expect(requests.contains { $0.1.contains("user_notes") && $0.1.contains("My private hypothesis") })
        #expect(summary.markdown.contains("User notes"))
    }

    @Test("Long Unicode speech and notes are bounded without dropping the final evidence")
    func boundedLongTranscript() async throws {
        let provider = RecordingSummaryProvider()
        let meeting = Meeting(id: "long", title: "Long meeting", userNotes: String(repeating: "note 🌿 ", count: 500) + "FINAL_NOTE")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: "c", speakerName: "Speaker 1", start: 0, end: 400, text: String(repeating: "Quoted evidence 🌿 ", count: 800) + "FINAL_TRANSCRIPT")
        _ = try await Summarizer(provider: provider).summarize(meeting: meeting, utterances: [utterance], attendees: [])
        let requests = await provider.recorded()
        #expect(requests.count > 1)
        #expect(requests.allSatisfy { $0.0.utf8.count + $0.1.utf8.count <= 1_800 })
        #expect(requests.contains { $0.1.contains("FINAL_TRANSCRIPT") })
        #expect(requests.contains { $0.1.contains("FINAL_NOTE") })
        // The outcomes pass re-reads the same chunks; coverage is checked on the summary pass.
        let evidence = requests.filter { !$0.0.hasPrefix("Extract explicit outcomes.") }.flatMap { request in request.1.components(separatedBy: "\n").compactMap { line -> [String: String]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        } }
        #expect(evidence.filter { $0["kind"] == "transcript" }.compactMap { $0["text"] }.joined() == utterance.text)
        #expect(evidence.filter { $0["kind"] == "user_notes" }.compactMap { $0["text"] }.joined() == meeting.userNotes)

    }

    @Test("Untimed text never supplies fabricated timestamps to the model")
    func untimedEvidence() async throws {
        let provider = RecordingSummaryProvider()
        let meeting = Meeting(id: "text", title: "Imported text", platform: "transcript_import")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: "", speakerName: "Unassigned", start: 0, end: 0, text: "Untimed source")
        _ = try await Summarizer(provider: provider).summarize(meeting: meeting, utterances: [utterance], attendees: [])
        let requests = await provider.recorded()
        #expect(requests.contains { $0.1.contains("untimed") })
        #expect(!requests.contains { $0.1.contains("00:00") })
    }
}

private struct FixedSummaryProvider: LLMProvider {
    let response: String
    let id = "fixed-fixture"
    let isLocal = true
    func generate(system: String, prompt: String) async throws -> String { response }
}

@Suite("Generated notes cannot silently lose evidence provenance")
struct SummaryCitationTests {
    @Test func rejectsUnsupportedOrUncitedClaims() async throws {
        let meeting = Meeting(id: "citations", title: "Citations")
        let speech = Utterance(id: 1, meetingId: meeting.id, clusterId: "c", speakerName: "Unassigned", start: 0, end: 1, text: "A possibility, not a commitment.")
        for response in ["- Everyone agreed [T9999].", "- Everyone agreed.", "- A possibility [T0001].\n- Ben owns all follow-ups."] {
            await #expect(throws: SummaryError.self) {
                try await Summarizer(provider: FixedSummaryProvider(response: response)).summarize(meeting: meeting, utterances: [speech], attendees: [])
            }
        }
    }
    @Test func providerFailureDoesNotReturnAnExtractiveSuccess() async throws {
        let meeting = Meeting(id: "empty", title: "Empty output")
        let speech = Utterance(id: 1, meetingId: meeting.id, clusterId: "c", speakerName: "Unknown", start: 1, end: 2, text: "Source remains available.")
        await #expect(throws: SummaryError.self) {
            try await Summarizer(provider: FixedSummaryProvider(response: "")).summarize(meeting: meeting, utterances: [speech], attendees: [])
        }
    }
}

@Suite("Explicit Apple on-device summary smoke")
struct FoundationModelsSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_LOCAL_SUMMARY"] == "1"))
    func normalLengthSyntheticFixture() async throws {
        guard FoundationModelsProvider.availability() == .available else { return }
        let meeting = Meeting(id: "fictional-normal-smoke", title: "Fictional observatory")
        let speech = Utterance(id: 1, meetingId: meeting.id, clusterId: "fixture", speakerName: "Fictional speaker", start: 0, end: 15,
            text: "This is speaker Amber in a synthetic meeting the observatory team will inspect the telescope on Tuesday we will check the lens compare the star charts and write a short report this sentence is generated for the recording test this is test turn one")
        let result = try await Summarizer(provider: FoundationModelsProvider()).summarize(meeting: meeting, utterances: [speech], attendees: [])
        #expect(result.markdown.contains("Generated notes (review required)"))
        #expect(result.markdown.contains("[T0001]"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_LOCAL_SUMMARY"] == "1"))
    func syntheticPublicFixtureOnly() async throws {
        let status = FoundationModelsProvider.availability()
        print("LOCAL_SUMMARY_AVAILABILITY: \(status.message)")
        guard status == .available else { return }
        let meeting = Meeting(id: "fictional-local-smoke", title: "Fictional kite fixture")
        let speech = Utterance(id: 1, meetingId: meeting.id, clusterId: "fixture", speakerName: "Fictional speaker", start: 12.5, end: 15,
            text: "We considered a fictional blue kite. No decision was made.")
        let result = try await Summarizer(provider: FoundationModelsProvider()).summarize(meeting: meeting, utterances: [speech], attendees: [])
        #expect(result.markdown.contains("Generated notes (review required)"))
        #expect(result.markdown.contains("[T0001]"))
        #expect(result.overview.localizedCaseInsensitiveContains("kite"))
        #expect(!result.markdown.contains("## Transcript\n"))
        #expect(!result.overview.localizedCaseInsensitiveContains("decided to"))
        print("LOCAL_SUMMARY_SYNTHETIC_DRAFT: \(result.overview)")
        print("LOCAL_SUMMARY_INFERENCE_COMPLETED: synthetic fixture only")
    }
}


@Suite("Summary command options without models")
struct SummaryCommandOptionsTests {
    @Test func validatesSelectionsBeforeInference() throws {
        let options = try SummaryCommandOptions(arguments: ["--engine", "apple", "--template", "standup", "--data-dir", "/tmp/test-only"])
        #expect(options.engine == .apple)
        #expect(options.template == .standup)
        #expect(try SummaryCommandOptions(arguments: []).engine == .extractive)
        for invalid in [["--engine", "cloud"], ["--template", "invented"], ["--engine"], ["--engine", "apple", "--engine", "extractive"], ["--unknown", "x"]] {
            #expect(throws: (any Error).self) { try SummaryCommandOptions(arguments: invalid) }
        }
    }
}
