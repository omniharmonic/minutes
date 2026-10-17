import Foundation
import Testing
import MinutesCore
@testable import MinutesApp

@MainActor struct RecordingReadinessTests {
    @Test func missingModelsBlockCaptureBeforeCreatingMeeting() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        var starts = 0
        let state = try AppState(store: store,
            recordingModelReadiness: { (false, "Install speaker models first") },
            captureStart: { _ in starts += 1 }, captureStop: { nil })
        state.startQuickMeeting()
        #expect(starts == 0)
        #expect(!state.isRecording)
        #expect(store.listMeetings().isEmpty)
        #expect(state.statusMessage.contains("Install"))
    }
    @Test func modelRemovalAfterReadinessCheckStillBlocksCapture() throws {
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"),
            recordingModelReadiness: { (false, "Models were removed") },
            captureStart: { _ in Issue.record("Capture must not start") }, captureStop: { nil })
        state.startQuickMeeting()
        #expect(!state.isRecording)
        #expect(state.store.listMeetings().isEmpty)
    }
    @Test func deniedPreflightCannotStartOrCreateMeeting() async throws {
        struct Denied: LocalizedError { var errorDescription: String? { "Speech permission denied" } }
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"),
            recordingModelReadiness: { (true, "Ready") },
            recordingEnvironmentPreflight: { throw Denied() },
            captureStart: { _ in Issue.record("Capture must not start") }, captureStop: { nil })
        #expect(await state.prepareRecording() == false)
        #expect(state.store.listMeetings().isEmpty)
        #expect(!state.isPreparingRecording)
        #expect(state.statusMessage.contains("Speech permission denied"))
    }
    @Test func missingModelsNeverRequestsOSPermissions() async throws {
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"),
            recordingModelReadiness: { (false, "Install local models") },
            recordingEnvironmentPreflight: { Issue.record("No permission prompt before setup") })
        #expect(await state.prepareRecording() == false)
    }
}
