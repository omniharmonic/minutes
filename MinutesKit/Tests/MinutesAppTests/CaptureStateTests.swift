import Foundation
import Testing
import MinutesCore
@testable import MinutesApp

@MainActor
struct CaptureStateTests {
    struct CaptureFailure: Error {}

    @Test("A failed microphone start never presents an active recording")
    func failedStartIsVisible() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-capture-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try MinutesStore(dbPath: dbURL.path)
        let state = try AppState(store: store, audioDirectory: FileManager.default.temporaryDirectory,
            recordingModelReadiness: { (true, "Fixture models ready") }, captureStart: { _ in throw CaptureFailure() }, captureStop: { nil })
        state.startQuickMeeting()
        #expect(!state.isRecording)
        #expect(state.statusMessage.contains("Recording failed"))
        #expect(store.listMeetings().first?.status == "failed")
    }

    @Test("A failed stop preserves the meeting and does not process incomplete audio")
    func failedStopIsVisible() async throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-capture-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try MinutesStore(dbPath: dbURL.path)
        let state = try AppState(store: store, audioDirectory: FileManager.default.temporaryDirectory,
            recordingModelReadiness: { (true, "Fixture models ready") }, captureStart: { _ in }, captureStop: { throw CaptureFailure() })
        state.startQuickMeeting()
        #expect(state.isRecording)
        await state.stopAndProcessMeeting()
        #expect(!state.isRecording)
        #expect(!state.isProcessing)
        #expect(state.statusMessage.contains("Recording failed"))
        #expect(store.listMeetings().first?.status == "failed")
    }
    @Test("Unavailable configured database blocks app startup instead of selecting temporary storage")
    func startupStorageFailureIsVisible() throws {
        let blockingFile = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-db-parent-\(UUID())")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let startup = AppStartup(databasePath: blockingFile.appendingPathComponent("minutes.sqlite").path)
        #expect(startup.state == nil)
        #expect(startup.errorMessage != nil)
        startup.retry()
        #expect(startup.state == nil)
    }

}
