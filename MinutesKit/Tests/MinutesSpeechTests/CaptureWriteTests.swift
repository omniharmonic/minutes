import AVFoundation
import Testing
@testable import MinutesSpeech

struct CaptureWriteTests {
    struct DiskFull: Error {}

    @Test("Disk write failures remain visible on finalization and do not advance duration")
    func failedFramesAreNotCounted() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in throw DiskFull() })
        state.append(buffer)
        #expect(state.duration == 0)
        #expect(state.bufferHealth.count == 0)
        #expect(state.bufferHealth.largestSeconds == 0)
        #expect(throws: DiskFull.self) { try state.finish() }
    }

    @Test("Successful committed buffers advance duration exactly")
    func successfulFramesAreCounted() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        state.append(buffer)
        state.append(buffer)
        try state.finish()
        #expect(state.duration == 0.02)
        #expect(state.bufferHealth.count == 2)
        #expect(state.bufferHealth.largestSeconds == 0.01)
    }
}

extension CaptureWriteTests {
    @Test("Lost microphone frames fail visibly and preserve the committed prefix")
    func stalledInputCannotFinalizeAsSilence() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        state.beginMonitoring(at: 0)
        state.append(buffer, at: 0.5)
        state.checkForStall(at: 3.6)
        #expect(state.errorDescription?.contains("stopped delivering audio") == true)
        #expect(state.duration == 0.01)
        #expect(throws: NSError.self) { try state.finish() }
    }

    @Test("Silent but advancing microphone frames stay healthy; startup without frames times out")
    func silenceIsNotAStall() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].update(repeating: 0, count: 160)
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        state.beginMonitoring(at: 0)
        for second in 1...10 { state.append(buffer, at: Double(second)); state.checkForStall(at: Double(second) + 0.1) }
        #expect(state.errorDescription == nil)
        try state.finish()
        state.checkForStall(at: 100)
        #expect(state.errorDescription == nil)
        let empty = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        empty.beginMonitoring(at: 0)
        empty.checkForStall(at: 4.9)
        #expect(empty.errorDescription == nil)
        empty.checkForStall(at: 5.1)
        #expect(empty.errorDescription != nil)
    }
}


extension CaptureWriteTests {
    @Test("Healthy configuration notification does not stop first capture; lost frames still fail")
    func healthyConfigurationIsNotFailure() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        state.beginMonitoring(at: 0)
        state.handleConfigurationChange(engineRunning: true, formatMatches: true, inputRouteMatches: true)
        #expect(state.errorDescription == nil)
        state.append(buffer, at: 0.2)
        state.handleConfigurationChange(engineRunning: true, formatMatches: true, inputRouteMatches: true)
        state.append(buffer, at: 0.3)
        #expect(state.duration == 0.02)
        #expect(state.errorDescription == nil)
        state.checkForStall(at: 3.4)
        #expect(state.errorDescription?.contains("stopped delivering audio") == true)
    }

    @Test("Stopped engine, changed format, or different input route remains a fatal capture change")
    func genuineConfigurationChangesFail() throws {
        for health in [(false, true, true), (true, false, true), (true, true, false)] {
            let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
            state.beginMonitoring(at: 0)
            state.handleConfigurationChange(engineRunning: health.0, formatMatches: health.1, inputRouteMatches: health.2)
            #expect(state.errorDescription?.contains("configuration changed") == true)
            #expect(throws: NSError.self) { try state.finish() }
        }
    }
}


extension CaptureWriteTests {
    @Test("Observed first-attempt halt permits one restart, coalesces pending events, then captures frames")
    func firstAttemptStartupRestart() throws {
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        state.beginMonitoring(at: 254911.904)
        #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 254912.161) == .restartEngine)
        #expect(state.canRestartEngine)
        #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 254912.17) == .waitForRestart)
        #expect(state.errorDescription == nil)
        state.completeStartupRestart(succeeded: true)
        #expect(!state.canRestartEngine)
        #expect(state.handleConfigurationChange(engineRunning: true, formatMatches: true, inputRouteMatches: true, at: 254912.2) == .keepRecording)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        state.append(buffer, at: 254912.3)
        #expect(state.duration == 0.01 && state.errorDescription == nil)
        #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 254912.4) == .failed)
        #expect(!state.canRestartEngine)
    }

    @Test("Startup restart never masks real changes, a second halt, late startup, or an explicit stop")
    func startupRestartBoundaries() throws {
        for changedRoute in [false, true] {
            let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
            state.beginMonitoring(at: 0)
            #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
            #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: changedRoute, inputRouteMatches: !changedRoute, at: 0.3) == .failed)
            #expect(!state.canRestartEngine)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for pending in [false, true] {
            let frames = CaptureWriteState(sampleRate: 16000, writer: { _ in })
            frames.beginMonitoring(at: 0)
            if pending {
                #expect(frames.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
            }
            frames.append(buffer, at: 0.3)
            #expect(!frames.canRestartEngine)
            #expect(frames.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.4) == .failed)
        }
        let twice = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        twice.beginMonitoring(at: 0)
        #expect(twice.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
        twice.completeStartupRestart(succeeded: true)
        #expect(twice.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.3) == .failed)
        let late = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        late.beginMonitoring(at: 0)
        #expect(late.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 5.1) == .failed)
        let stopped = CaptureWriteState(sampleRate: 16000, writer: { _ in })
        stopped.beginMonitoring(at: 0)
        #expect(stopped.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
        try stopped.finish()
        #expect(!stopped.canRestartEngine)
        stopped.completeStartupRestart(succeeded: true)
        #expect(!stopped.canRestartEngine)
    }

    @Test("Failed restart is visible and successful restart does not reset the five-second frame watchdog")
    func startupRestartFailureAndWatchdog() throws {
        for succeeded in [false, true] {
            let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
            state.beginMonitoring(at: 0)
            #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
            state.completeStartupRestart(succeeded: succeeded)
            if succeeded { #expect(state.errorDescription == nil) }
            else { #expect(state.errorDescription != nil) }
            state.checkForStall(at: 5.1)
            #expect(state.errorDescription != nil)
            #expect(throws: NSError.self) { try state.finish() }
        }
    }
}


extension CaptureWriteTests {
    @Test("Restart reservation linearizes with frame append and sticky failures without holding callbacks")
    func startupReservationLinearizesWithCallbacks() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        func pending() -> CaptureWriteState {
            let state = CaptureWriteState(sampleRate: 16000, writer: { _ in })
            state.beginMonitoring(at: 0)
            #expect(state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2) == .restartEngine)
            return state
        }
        let earlierFrame = pending()
        earlierFrame.append(buffer, at: 0.3)
        #expect(!earlierFrame.reserveStartupRestart(at: 0.4))
        let duringRestart = pending()
        #expect(duringRestart.reserveStartupRestart(at: 0.4))
        #expect(!duringRestart.reserveStartupRestart(at: 0.4))
        // Simulate a callback inside engine.start(): it must not deadlock, commit
        // across a reserved graph restart, or disappear without a visible failure.
        duringRestart.append(buffer, at: 0.3)
        #expect(duringRestart.duration == 0)
        #expect(duringRestart.errorDescription != nil)
        #expect(duringRestart.restartRacedFrames)
        #expect(!duringRestart.completeStartupRestart(succeeded: true))
        #expect(throws: NSError.self) { try duringRestart.finish() }
        let fatal = pending()
        #expect(fatal.reserveStartupRestart(at: 0.4))
        fatal.recordFailure(DiskFull())
        #expect(!fatal.completeStartupRestart(succeeded: true))
        #expect(throws: DiskFull.self) { try fatal.finish() }
        let healthy = pending()
        #expect(healthy.reserveStartupRestart(at: 0.4))
        #expect(healthy.completeStartupRestart(succeeded: true))
        healthy.append(buffer, at: 0.3)
        #expect(healthy.duration == 0.01 && healthy.errorDescription == nil)
        let stopped = pending()
        #expect(stopped.reserveStartupRestart(at: 0.4))
        try stopped.finish()
        #expect(!stopped.completeStartupRestart(succeeded: true))
        #expect(!stopped.reserveStartupRestart(at: 0.4))
    }
}


extension CaptureWriteTests {
    @Test("Zero-frame rebuild retires old callbacks and accepts first new graph frames during engine.start")
    func generationHandoffKeepsWriter() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        var writes = 0
        let state = CaptureWriteState(sampleRate: 16000, writer: { _ in writes += 1 })
        state.beginMonitoring(at: 0)
        let old = state.generation
        _ = state.handleConfigurationChange(engineRunning: false, formatMatches: true, inputRouteMatches: true, at: 0.2)
        #expect(state.reserveStartupRestart(at: 0.3))
        let fresh = state.generation
        #expect(fresh != old)
        #expect(!state.acceptsGeneration(old))
        state.append(buffer, at: 0.31, generation: old)
        state.recordFailure(DiskFull(), generation: old)
        #expect(writes == 0 && state.errorDescription == nil)
        #expect(state.commitStartupGeneration(fresh, at: 0.4))
        state.append(buffer, at: 0.41, generation: fresh) // Synchronous callback inside new engine.start.
        #expect(writes == 1 && state.duration == 0.01)
        #expect(state.completeStartupRestart(succeeded: true))
        state.append(buffer, at: 0.5, generation: fresh)
        #expect(writes == 2 && state.duration == 0.02 && state.errorDescription == nil)
        #expect(!state.reserveStartupRestart(at: 0.6))
        try state.finish()
        #expect(!state.acceptsGeneration(fresh))
    }
}
