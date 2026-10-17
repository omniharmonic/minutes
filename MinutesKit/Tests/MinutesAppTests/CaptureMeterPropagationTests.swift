import Foundation
import Combine
import AVFoundation
import Testing
import MinutesCore
@testable import MinutesApp

@MainActor
struct CaptureMeterPropagationTests {
    @Test("Recorder metrics publish independent microphone level changes even at unchanged duration")
    func liveLevelsPropagate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-meter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db.sqlite").path)
        var level: Float = 0.25
        let state = try AppState(store: store, audioDirectory: root,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { nil },
            captureMetrics: { (1, level, nil) })
        var observed: [Float] = []
        let subscription = state.recordingMeter.$snapshot.sink { observed.append($0.level ?? 0) }
        state.startQuickMeeting()
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingDuration == 1)
        #expect(state.recordingLevel == 0.25)
        level = 0.8
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingDuration == 1)
        #expect(state.recordingLevel == 0.8)
        #expect(observed.suffix(2) == [0.25, 0.8])
        state.isRecording = false
        level = 1
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingLevel == 0.8)
        subscription.cancel()
    }
    @Test("Twenty hertz meter samples do not invalidate AppState within the same second")
    func highFrequencyMeterIsIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-meter-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db.sqlite").path)
        var elapsed = 0.05
        var polls = 0
        let state = try AppState(store: store, audioDirectory: root,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { nil },
            captureMetrics: { polls += 1; return (elapsed, 0.4, nil) })
        state.startQuickMeeting()
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingDuration > 0) // Prompt Starting → Recording transition.
        var appChanges = 0
        var meterChanges = 0
        let appSubscription = state.objectWillChange.sink { appChanges += 1 }
        let meterSubscription = state.recordingMeter.objectWillChange.sink { meterChanges += 1 }
        for index in 2...19 {
            elapsed = Double(index) * 0.05
            state.updateMicrophoneCaptureMetrics()
        }
        #expect(appChanges == 0)
        #expect(meterChanges == 18)
        #expect(polls == 19)
        #expect(state.recordingLevel == 0.4)
        #expect(state.recordingMeter.duration == elapsed)
        #expect(state.recordingMeter.snapshot.history.suffix(19).allSatisfy { $0 == 0.4 })
        elapsed = 1.05
        state.updateMicrophoneCaptureMetrics()
        #expect(appChanges == 1)
        #expect(state.recordingDuration == 1.05)
        // Polling a stalled committed-audio clock must not invent waveform samples.
        let history = state.recordingMeter.snapshot.history
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingMeter.snapshot.history == history)
        #expect(appChanges == 1)
        appSubscription.cancel(); meterSubscription.cancel()
    }

    @Test("Stop publishes exact finalized audio duration rather than the last live display sample")
    func stopUsesFinalizedDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-meter-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000)!
            buffer.frameLength = 2_000
            buffer.floatChannelData![0].update(repeating: 0, count: 2_000)
            try file.write(from: buffer)
        }
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db.sqlite").path)
        let state = try AppState(store: store, audioDirectory: root,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in }, captureStop: { audio },
            captureMetrics: { (0.05, 0.4, nil) }, processAudio: { _, _, _ in throw CancellationError() })
        state.startQuickMeeting()
        state.updateMicrophoneCaptureMetrics()
        #expect(state.recordingDuration == 0.05)
        await state.stopAndProcessMeeting()
        #expect(state.recordingDuration == 0.125)
        #expect(state.recordingMeter.duration == 0.125)
        #expect(state.recordingLevel == 0)
    }

}
