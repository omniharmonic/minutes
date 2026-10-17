import Foundation
import Testing
import MinutesCore
@testable import MinutesApp

@MainActor
struct CaptureRouteNoticeTests {
    @Test("Route recovery is visible without stopping a healthy recording or repeatedly publishing notices")
    func nonfatalRouteNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-route-notice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var notice: String?
        let state = try AppState(store: MinutesStore(dbPath: root.appendingPathComponent("fixture.sqlite").path), audioDirectory: root,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { nil },
            captureMetrics: { (1, 0.3, nil) }, captureNotice: { notice })
        state.startQuickMeeting()
        state.updateMicrophoneCaptureMetrics()
        notice = "Microphone reconnected. A brief gap may be present."
        state.updateMicrophoneCaptureMetrics()
        #expect(state.isRecording)
        #expect(state.statusMessage == notice)
        state.statusMessage = "Separate progress message"
        state.updateMicrophoneCaptureMetrics()
        #expect(state.statusMessage == "Separate progress message", "Repeated route polls must not overwrite new feedback")
        state.isRecording = false
    }
}
