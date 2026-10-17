#if os(macOS)
import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor private final class SystemRecorderFixture: SystemAudioRecording {
    var captureError: String?
    var capturing = false
    var directory: URL?
    var includedMicrophone: Bool?
    var failStart = false
    var failFinish = false
    func startRecording(to directory: URL, includeMicrophone: Bool) async throws {
        includedMicrophone = includeMicrophone
        if failStart { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory; capturing = true
    }
    func stopRecording() async throws -> SynchronizedCaptureResult {
        capturing = false
        let root = directory!
        let result = SynchronizedCaptureResult(directory: root, systemAudioURL: root.appendingPathComponent("system.caf"), microphoneURL: root.appendingPathComponent("microphone.caf"), processingURL: failFinish ? nil : root.appendingPathComponent("mixed.caf"), manifestURL: root.appendingPathComponent("capture.json"), duration: 0.1, issues: failFinish ? ["Synthetic incomplete source"] : [])
        if failFinish { throw CaptureFinalizationError(result: result) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.01 }
        do { let file = try AVAudioFile(forWriting: result.processingURL!, settings: format.settings); try file.write(from: buffer) }
        return result
    }
}
@MainActor struct SystemCaptureFlowTests {
    @Test("Device-only source never enables microphone capture")
    func systemOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-system-only-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SystemRecorderFixture()
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: root, systemRecorder: recorder,
            recordingModelReadiness: { (true, "Fixture models ready") },
            processAudio: { id, _, _ in PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000,
                words: [], segments: [], clusters: [], utterances: [], speechDuration: 0) })
        state.captureMode = .systemAudio
        #expect(!state.captureMode.includesMicrophone)
        state.startQuickMeeting()
        for _ in 0..<100 where !state.isRecording { await Task.yield() }
        #expect(state.isRecording)
        #expect(recorder.includedMicrophone == false)
        #expect(state.statusMessage.contains("Microphone is off"))
        await state.stopAndProcessMeeting()
        #expect(!state.isRecording)
    }

    @Test("Incomplete system audio never reaches processing and preserves source files")
    func systemFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-system-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SystemRecorderFixture()
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: root, systemRecorder: recorder, recordingModelReadiness: { (true, "Fixture models ready") })
        await state.startSystemMeeting()
        #expect(state.isRecording)
        recorder.failFinish = true
        await state.stopAndProcessMeeting()
        #expect(!state.isRecording)
        #expect(!state.isProcessing)
        #expect(state.currentMeeting?.status == "failed")
        #expect(state.statusMessage.contains("preserved"))
        #expect(state.currentUtterances.isEmpty)
    }
    @Test("A finalized system mix is persisted and passed to the shared pipeline")
    func successfulMix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-system-success-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SystemRecorderFixture()
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: root, systemRecorder: recorder, recordingModelReadiness: { (true, "Fixture models ready") },
            processAudio: { id, url, _ in
                #expect(url.lastPathComponent == "mixed.caf")
                return PipelineResult(meetingId: id, audioDuration: 0.1, sampleRate: 16000, words: [], segments: [], clusters: [], utterances: [Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Unknown", start: 0, end: 0.1, text: "Synthetic pipeline fixture")], speechDuration: 0.1)
            })
        await state.startSystemMeeting()
        #expect(state.isRecording)
        await state.stopAndProcessMeeting()
        #expect(state.currentMeeting?.status == "needs_review")
        #expect(state.currentMeeting?.audioPath?.hasSuffix("mixed.caf") == true)
        #expect(state.currentUtterances.first?.text == "Synthetic pipeline fixture")
        #expect(!state.isRecording && !state.isProcessing && !state.isFinalizingRecording)
    }
    @Test("A rejected system capture start never displays an active recording")
    func startFailure() async throws {
        let recorder = SystemRecorderFixture(); recorder.failStart = true
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), audioDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), systemRecorder: recorder, recordingModelReadiness: { (true, "Fixture models ready") })
        await state.startSystemMeeting()
        #expect(!state.isRecording)
        #expect(!state.isStartingRecording)
        #expect(state.statusMessage.contains("failed"))
    }
}
#endif
