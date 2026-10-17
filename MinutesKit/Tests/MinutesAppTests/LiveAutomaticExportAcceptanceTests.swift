import Foundation
import Testing
import MinutesCore
import MinutesExport
@testable import MinutesApp

@MainActor struct LiveAutomaticExportAcceptanceTests {
    @Test("Synthetic AI summary automatically reaches the restricted staging vault",
          .enabled(if: ProcessInfo.processInfo.environment["MINUTES_LIVE_PRISM"] == "1"))
    func syntheticSummaryDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-auto-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "minutes-auto-export-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("test.sqlite").path)
        let connection = try PrismConnection(origin: URL(string: "https://minutes.omniharmonic.com")!, store: store)
        let state = try AppState(store: store, preferences: preferences, prismConnection: connection)
        await state.restorePrismConnection()
        try #require(state.prismVerified && state.prismVaultID == "minutes-staging", "Requires existing restricted staging authorization")
        state.prismDirectory = "Minutes-Test/AutomaticSummary"
        state.summaryUsesAppleIntelligence = true
        state.autoFileMeetingsEnabled = false
        state.autoExportPrism = true
        let input = root.appendingPathComponent("Synthetic observatory meeting.txt")
        try "Maya will inspect the telescope lens on Tuesday. Leo will compare the star charts by Thursday. We decided to postpone the public demonstration until the safety checklist is complete. The equipment budget is three hundred dollars.".write(to: input, atomically: true, encoding: .utf8)
        let meeting = try await state.importMedia(from: input, isTranscript: true)
        await state.generateCurrentSummary()
        #expect(store.getSummary(meetingId: meeting.id) != nil)
        let delivery = try #require(store.listOutboxItems(meetingId: meeting.id).first)
        #expect(delivery.status == .synced)
        #expect(!state.statusMessage.contains("Waiting for a committed receipt"))
        #expect(delivery.destinationVault == "minutes-staging")
        #expect(delivery.receipt?.meetingNoteId != nil)
        let payload = try JSONDecoder().decode(PrismMeetingPayload.self, from: Data(delivery.payloadJson.utf8))
        #expect(payload.destinationDirectory == "Minutes-Test/AutomaticSummary")
        #expect(!payload.summary.markdown.isEmpty && !payload.utterances.isEmpty)
        let priorID = delivery.id
        await state.syncPrismOutbox()
        #expect(store.listOutboxItems(meetingId: meeting.id).count == 1)
        #expect(store.getOutboxItem(id: priorID)?.status == .synced)
        // Explicit highlights are not an AI summary and must not auto-share.
        state.summaryUsesAppleIntelligence = false
        let highlightsOnly = try await state.importMedia(from: input, isTranscript: true)
        await state.generateCurrentSummary()
        #expect(store.listOutboxItems(meetingId: highlightsOnly.id).isEmpty)
        // Turning the preference off also prevents a later manual AI summary
        // from being uploaded automatically.
        state.autoExportPrism = false
        state.summaryUsesAppleIntelligence = true
        await state.generateCurrentSummary()
        #expect(store.listOutboxItems(meetingId: highlightsOnly.id).isEmpty)
    }
}
