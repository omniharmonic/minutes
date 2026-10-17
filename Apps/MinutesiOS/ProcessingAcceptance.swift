#if DEBUG
import Foundation
import SwiftUI
import MinutesCore

/// Explicit developer launch only; never uses the personal meeting database.
@MainActor enum ProcessingAcceptance {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--minutes-lock-acceptance") }
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var events: [[String: String]] = []
    static func makeState() throws -> AppState {
        let directory = documents.appendingPathComponent("Minutes-Acceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = UserDefaults(suiteName: "Minutes-Synthetic-Acceptance")!
        preferences.set(true, forKey: "summaryUsesAppleIntelligence")
        preferences.set(false, forKey: "autoExportPrism")
        return try AppState(databasePath: directory.appendingPathComponent("acceptance.sqlite").path,
            audioDirectory: directory.appendingPathComponent("audio"), preferences: preferences)
    }
    static func record(_ event: String, state: AppState) {
        guard enabled else { return }
        events.append(["time": ISO8601DateFormatter().string(from: Date()), "event": event,
            "processing": String(state.isProcessing), "summarizing": String(state.isSummarizing),
            "status": state.statusMessage, "prism": state.prismMessage])
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("Minutes-Acceptance-report.json"), options: .atomic)
        }
    }
    static func run(state: AppState) async {
        guard enabled else { return }
        events = []
        record("start", state: state)
        await state.restorePrismConnection()
        // Only the explicitly authorized disposable staging vault may receive fixtures.
        if state.prismVerified && state.prismVaultID == "minutes-staging" {
            state.prismDirectory = "Minutes-Test/LockAcceptance"
            state.autoExportPrism = true
        }
        state.summaryUsesAppleIntelligence = true
        record("ready", state: state)
        do {
            try await Task.sleep(for: .seconds(2))
            _ = try await state.importMedia(from: documents.appendingPathComponent("Minutes-Acceptance.wav"), title: "Synthetic lock acceptance")
            record("finished", state: state)
        } catch {
            state.statusMessage = "Acceptance failed: \(error.localizedDescription)"
            record("failed", state: state)
        }
    }
}
#endif
