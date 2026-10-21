import Foundation
import Testing
@testable import MinutesSummarize

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
}
