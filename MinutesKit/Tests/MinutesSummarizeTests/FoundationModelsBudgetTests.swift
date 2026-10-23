import Foundation
import Testing
@testable import MinutesSummarize
#if canImport(FoundationModels)
import FoundationModels
#endif

struct FoundationModelsBudgetTests {
    @Test func largerContextsFitMoreTranscriptPerRequest() {
        #expect(FoundationModelsProvider.inputBudget(contextTokens: 4_096) == 2_800)
        #expect(FoundationModelsProvider.inputBudget(contextTokens: 8_192) == 6_892)
        #expect(FoundationModelsProvider.inputBudget(contextTokens: 1_024) == 2_800)
    }

    actor Attempts { var count = 0; func next() -> Int { count += 1; return count } }

    @Test func busyModelIsRetriedUntilItAnswers() async throws {
        let attempts = Attempts()
        let answer = try await FoundationModelsProvider.retryingBusy(delays: [.zero, .zero, .zero]) {
            if await attempts.next() < 3 { throw LocalSummaryProviderError.busy }
            return "notes"
        }
        #expect(answer == "notes")
        #expect(await attempts.count == 3)
    }

    @Test func busyModelFailsOnceRetriesRunOutAndOtherErrorsAreNotRetried() async {
        let busy = Attempts()
        await #expect(throws: LocalSummaryProviderError.self) {
            try await FoundationModelsProvider.retryingBusy(delays: [.zero, .zero]) { () async throws -> String in
                _ = await busy.next(); throw LocalSummaryProviderError.busy
            }
        }
        #expect(await busy.count == 3)
        let declined = Attempts()
        await #expect(throws: LocalSummaryProviderError.self) {
            try await FoundationModelsProvider.retryingBusy(delays: [.zero, .zero]) { () async throws -> String in
                _ = await declined.next(); throw LocalSummaryProviderError.contentDeclined
            }
        }
        #expect(await declined.count == 1)
    }

    // iPhone 2026-10-22: iOS 27's default guardrails declined every chunk of a
    // 12-minute meeting; permissive text is tried first, guided generation second.
    @Test func textIsTriedFirstAndGuidedOnlyWhenTextIsUnusable() async throws {
        let guided = Attempts()
        let answer = try await FoundationModelsProvider.preferringText(
            text: { "- Point [T0001]" }, guided: { _ = await guided.next(); return "" })
        #expect(answer == "- Point [T0001]")
        #expect(await guided.count == 0)
        let fallback = try await FoundationModelsProvider.preferringText(
            text: { () async throws -> String in throw LocalSummaryProviderError.contentDeclined },
            guided: { "- Guided [T0002]" })
        #expect(fallback == "- Guided [T0002]")
        let failed = try await FoundationModelsProvider.preferringText(
            text: { () async throws -> String in throw LocalSummaryProviderError.generationFailed },
            guided: { "- Guided [T0003]" })
        #expect(failed == "- Guided [T0003]")
    }

    @Test func busyTextIsRetriedRatherThanSwitchingToGuided() async {
        let guided = Attempts()
        await #expect(throws: LocalSummaryProviderError.self) {
            try await FoundationModelsProvider.preferringText(
                text: { () async throws -> String in throw LocalSummaryProviderError.busy },
                guided: { _ = await guided.next(); return "" })
        }
        #expect(await guided.count == 0)
    }

    @Test func uncitedTextIsUnusableButOutcomesMayBeEmpty() throws {
        #expect(throws: LocalSummaryProviderError.self) {
            try FoundationModelsProvider.citedText("I can't help with that.", outcomes: false, prompt: "")
        }
        #expect(throws: LocalSummaryProviderError.self) {
            try FoundationModelsProvider.citedText("- A point with no source", outcomes: false, prompt: "")
        }
        #expect(try FoundationModelsProvider.citedText("None", outcomes: true, prompt: "") == "")
        #expect(try FoundationModelsProvider.citedText("- Decision: Ship it [T0001]", outcomes: true, prompt: "") == "- Decision: Ship it [T0001]")
        #expect(try FoundationModelsProvider.citedText("Notes:\n- Ship Friday [T0001]", outcomes: false, prompt: "") == "- Ship Friday [T0001]")
    }

    @Test func plainEvidenceKeepsIDsSpeakersAndNotesButDropsJSON() {
        let prompt = """
        Template: General
        {"kind":"meeting_title","id":"metadata","timing":"untimed","text":"Planning"}
        {"kind":"transcript","id":"T0001","speaker":"Ana","timing":"00:00","text":"We ship Friday."}
        {"kind":"transcript","id":"T0002","speaker":"Unknown","timing":"00:05","text":"Sounds good."}
        {"kind":"draft_summary","id":"T0003","additionalIDs":"T0004 T0005","timing":"","text":"Ship Friday."}
        {"kind":"user_notes","id":"N0001","timing":"untimed","text":"Ask about budget"}
        """
        #expect(FoundationModelsProvider.plainEvidence(prompt) == """
        Meeting: Planning
        Transcript:
        [T0001] Ana: We ship Friday.
        [T0002] Sounds good.
        [T0003] [T0004] [T0005] Ship Friday.
        [N0001] Personal note: Ask about budget
        """)
    }

    @Test func looseCitationsAreNormalizedIntoBrackets() {
        #expect(FoundationModelsProvider.normalizedCitations("- Ship Friday. [T0003, T0004]") == "- Ship Friday. [T0003] [T0004]")
        #expect(FoundationModelsProvider.normalizedCitations("- Ship Friday (T0003).") == "- Ship Friday. [T0003]")
        #expect(FoundationModelsProvider.normalizedCitations("- Ship Friday. Source IDs: T0003 and T0005") == "- Ship Friday. [T0003] [T0005]")
        #expect(FoundationModelsProvider.normalizedCitations("- Ship Friday. [T0003] [T0003]") == "- Ship Friday. [T0003]")
        #expect(FoundationModelsProvider.normalizedCitations("- Ship Friday.") == "- Ship Friday.")
    }

    @Test func textBulletsKeepOnlyBulletsAndDropARefusal() {
        #expect(FoundationModelsProvider.textBullets("Here are the notes:\n- One [T0001]\n  * Two [T0002]\nThanks") == ["- One [T0001]", "- Two [T0002]"])
        #expect(FoundationModelsProvider.textBullets("I'm sorry, I can't help with that.").isEmpty)
    }

    #if canImport(FoundationModels)
    @Test func languageModelErrorsMapToChunkOrRetryableFailures() throws {
        guard #available(macOS 27, iOS 27, *) else { return }  // GenerationError on 26
        func kind(_ error: LanguageModelError) -> String { String(describing: FoundationModelsProvider.providerError(error)) }
        #expect(kind(.guardrailViolation(.init(debugDescription: ""))) == "contentDeclined")
        #expect(kind(.refusal(.init(explanation: "", debugDescription: ""))) == "contentDeclined")
        #expect(kind(.rateLimited(.init(resetDate: nil, debugDescription: ""))) == "busy")
        #expect(kind(.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: ""))) == "contextLimit")
    }
    #endif
}
