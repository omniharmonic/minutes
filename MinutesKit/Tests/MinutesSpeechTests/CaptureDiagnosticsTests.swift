import Foundation
import Testing
@testable import MinutesSpeech

struct CaptureDiagnosticsTests {
    @Test("Capture diagnostics persist bounded numeric health, deduplicate failure and contain no source content")
    func boundedNumericEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        let diagnostics = CaptureDiagnostics(audioURL: audio)
        for index in 0..<30 {
            diagnostics.record(.configurationChecked, committedSeconds: Double(index), engineRunning: true,
                formatMatches: true, inputRouteMatches: index != 29, hasFailure: index == 29)
        }
        for _ in 0..<5 { diagnostics.record(.captureFailed, committedSeconds: 29, engineRunning: false, hasFailure: true) }
        diagnostics.waitForPendingWrites()
        let data = try Data(contentsOf: audio.appendingPathExtension("capture-diagnostics.json"))
        let entries = try JSONDecoder().decode([CaptureDiagnostics.Entry].self, from: data)
        #expect(entries.count == 16)
        #expect(entries.filter { $0.event == .captureFailed }.count == 1)
        #expect(entries.last?.hasFailure == true)
        #expect(entries.dropLast().last?.inputRouteMatches == false)
        let payload = String(decoding: data, as: UTF8.self)
        #expect(!payload.contains("fixture") && !payload.contains(root.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }
    @Test("Failure diagnostics retain NSError domain/code and stage without private userInfo")
    func errorMetadataOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        let diagnostics = CaptureDiagnostics(audioURL: audio)
        diagnostics.record(.restartFailed, committedSeconds: 0, engineRunning: false, hasFailure: true,
            failureStage: .sessionActivation, error: NSError(domain: "FixtureAudioSession", code: 123,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE ERROR", "privatePath": root.path]))
        diagnostics.waitForPendingWrites()
        let data = try Data(contentsOf: audio.appendingPathExtension("capture-diagnostics.json"))
        let entries = try JSONDecoder().decode([CaptureDiagnostics.Entry].self, from: data)
        #expect(entries.first?.errorDomain == "FixtureAudioSession")
        #expect(entries.first?.errorCode == 123)
        #expect(entries.first?.failureStage == .sessionActivation)
        let payload = String(decoding: data, as: UTF8.self)
        #expect(!payload.contains("PRIVATE") && !payload.contains(root.path) && !payload.contains("userInfo"))
    }

}
