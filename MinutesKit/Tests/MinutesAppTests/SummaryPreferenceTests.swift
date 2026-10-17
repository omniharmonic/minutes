import Foundation
import Testing
import MinutesCore
import MinutesSummarize
@testable import MinutesApp

@MainActor struct SummaryPreferenceTests {
    @Test(arguments: [false, true])
    func explicitSummaryChoiceIsPreserved(savedChoice: Bool) throws {
        let suite = "minutes-summary-choice-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(savedChoice, forKey: "summaryUsesAppleIntelligence")
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: preferences)
        #expect(state.summaryUsesAppleIntelligence == savedChoice)
    }
    @Test func freshChoiceUsesAvailabilityWithoutPersistingAnImplicitOptOut() throws {
        let suite = "minutes-summary-default-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: preferences)
        #expect(state.summaryUsesAppleIntelligence == (FoundationModelsProvider.availability() == .available))
        #expect(preferences.object(forKey: "summaryUsesAppleIntelligence") == nil)
    }
}
