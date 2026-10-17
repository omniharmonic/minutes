import Foundation
import Testing
import AVFoundation
@testable import MinutesSpeech

struct CaptureRouteRecoveryTests {
    @Test("Output-only connection preserves a healthy input; changed or disconnected input rebuilds")
    func routePolicy() {
        #expect(!CaptureRoutePolicy.shouldRebuild(engineRunning: true, formatMatches: true, inputRouteMatches: true, hasCommittedAudio: true))
        #expect(CaptureRoutePolicy.shouldRebuild(engineRunning: true, formatMatches: true, inputRouteMatches: false, hasCommittedAudio: true))
        #expect(CaptureRoutePolicy.shouldRebuild(engineRunning: true, formatMatches: false, inputRouteMatches: true, hasCommittedAudio: true))
        #expect(CaptureRoutePolicy.shouldRebuild(engineRunning: false, formatMatches: true, inputRouteMatches: true, hasCommittedAudio: true))
        #expect(!CaptureRoutePolicy.shouldRebuild(engineRunning: false, formatMatches: true, inputRouteMatches: true, hasCommittedAudio: false))
    }

    @Test("Recovery restart still requires real frames within the watchdog deadline")
    func recoveryWatchdog() {
        let state = CaptureWriteState(sampleRate: 16000) { _ in }
        state.beginMonitoring(at: 0)
        _ = state.beginRouteRecovery(at: 1)
        state.completeRouteRecovery(succeeded: true, at: 2)
        state.checkForStall(at: 7.1)
        #expect(state.errorDescription != nil)
    }

    @Test("Route recovery preserves committed frames and rejects retired callbacks")
    func preservesFramesAcrossRoutes() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        var writes = 0
        let state = CaptureWriteState(sampleRate: 16000) { _ in writes += 1 }
        state.beginMonitoring(at: 0)
        state.append(buffer, at: 1, generation: 0)
        let generation = try #require(state.beginRouteRecovery(at: 2))
        #expect(generation == 1)
        #expect(state.beginRouteRecovery(at: 2.1) == nil)
        state.append(buffer, at: 2.2, generation: 0)
        #expect(writes == 1)
        state.checkForStall(at: 6)
        #expect(state.errorDescription == nil)
        state.append(buffer, at: 6.1, generation: generation)
        state.completeRouteRecovery(succeeded: true, at: 6.1)
        #expect(writes == 2)
        #expect(state.duration == 0.2)
        #expect(state.captureNotice != nil)
        try state.finish()
    }

    @Test("Missing input recovery is bounded and retains prior audio on failure")
    func boundedMissingInput() throws {
        let state = CaptureWriteState(sampleRate: 16000) { _ in }
        state.beginMonitoring(at: 0)
        _ = state.beginRouteRecovery(at: 2)
        state.checkForStall(at: 7.1)
        #expect(state.errorDescription != nil)
        #expect(state.beginRouteRecovery(at: 7.2) == nil)
        #expect(throws: NSError.self) { try state.finish() }
    }

    @Test("Stopping while recovery is queued prevents stale graph callbacks")
    func stopDuringRecovery() throws {
        let state = CaptureWriteState(sampleRate: 16000) { _ in }
        state.beginMonitoring(at: 0)
        let generation = try #require(state.beginRouteRecovery(at: 1))
        try state.finish()
        #expect(!state.acceptsGeneration(generation))
        state.completeRouteRecovery(succeeded: false)
        #expect(state.errorDescription == nil)
    }
    @Test("The same WAV remains decodable with preserved samples across native format changes")
    func fixedFormatFileSurvivesRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        func makeState() throws -> CaptureWriteState {
            let file = try AVAudioFile(forWriting: url, settings: output.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            return CaptureWriteState(sampleRate: 16000) { try file.write(from: $0) }
        }
        let state = try makeState()
        state.beginMonitoring(at: 0)
        func appendNative(rate: Double, channels: AVAudioChannelCount, generation: Int, at time: Double) throws {
            let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(rate))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(channels) {
                buffer.floatChannelData![channel].update(repeating: 0.25, count: Int(buffer.frameLength))
            }
            let result = try CaptureTapConverter(outputFormat: output).convert(buffer)
            let converted = try #require(result)
            state.append(converted, at: time, generation: generation)
        }
        try appendNative(rate: 48000, channels: 1, generation: 0, at: 1)
        let firstDuration = state.duration
        let generation = try #require(state.beginRouteRecovery(at: 1.1))
        try appendNative(rate: 24000, channels: 2, generation: generation, at: 1.2)
        state.completeRouteRecovery(succeeded: true, at: 1.2)
        try state.finish()
        let saved = try AVAudioFile(forReading: url)
        #expect(saved.processingFormat.sampleRate == 16000)
        #expect(saved.processingFormat.channelCount == 1)
        #expect(state.duration > firstDuration)
        #expect(saved.length == Int64((state.duration * 16000).rounded()))
        #expect(saved.length > 30000)
        let decoded = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: AVAudioFrameCount(saved.length))!
        try saved.read(into: decoded)
        #expect(abs(decoded.floatChannelData![0][1000] - 0.25) < 0.01)
        #expect(abs(decoded.floatChannelData![0][Int(decoded.frameLength) - 1000] - 0.25) < 0.01)
    }

}
