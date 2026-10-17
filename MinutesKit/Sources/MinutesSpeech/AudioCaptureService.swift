import Foundation
import AVFoundation

/// Counts only committed frames and retains the first failure until finalization.
/// The injected writer lets disk failures be tested without opening a microphone.
final class CaptureWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: ((AVAudioPCMBuffer) throws -> Void)?
    private var failure: Error?
    private var frameCount: Int64 = 0
    private var committedBuffers = 0
    private var largestBufferSeconds: Double = 0
    private let sampleRate: Double
    private var monitoringStartedAt: TimeInterval?
    private var lastCommittedFrameAt: TimeInterval?
    private var startupRestartUsed = false
    private var startupRestartPending = false
    private var startupRestartReserved = false
    private var startupRestartRacedFrames = false
    private var activeGeneration = 0
    private var startupGenerationCommitted = false
    private var routeRecoveryStartedAt: TimeInterval?
    private var routeNotice: String?

    init(sampleRate: Double, writer: @escaping (AVAudioPCMBuffer) throws -> Void) {
        self.sampleRate = sampleRate
        self.writer = writer
    }

    func beginMonitoring(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { monitoringStartedAt = time }
    }

    func checkForStall(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, writer != nil, let startedAt = monitoringStartedAt else { return }
        if let recoveryStarted = routeRecoveryStartedAt, time - recoveryStarted <= 5 { return }
        let lastProgress = lastCommittedFrameAt ?? startedAt
        let grace: TimeInterval = lastCommittedFrameAt == nil ? 5 : 3
        if time - lastProgress > grace {
            failure = NSError(domain: "AudioCaptureService", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The microphone stopped delivering audio, possibly after an audio device change. Recorded audio was preserved. Choose a stable input device and start a new recording."])
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, generation: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == nil || generation == activeGeneration else { return }
        guard failure == nil, let writer else { return }
        if startupRestartReserved, !startupGenerationCommitted, buffer.frameLength > 0 {
            startupRestartRacedFrames = true
            failure = NSError(domain: "AudioCaptureService", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Audio arrived while the microphone was restarting. This attempt stopped to avoid an uncertain recording gap. Any saved audio was preserved. Start a new recording."])
            return
        }
        do {
            try writer(buffer)
            CaptionAudioFeed.shared.offer(buffer, source: "Microphone")
            frameCount += Int64(buffer.frameLength)
            if buffer.frameLength > 0 {
                lastCommittedFrameAt = time
                committedBuffers += 1
                largestBufferSeconds = max(largestBufferSeconds, Double(buffer.frameLength) / sampleRate)
            }
        } catch { failure = error }
    }

    enum ConfigurationAction { case keepRecording, restartEngine, waitForRestart, failed }

    @discardableResult
    func handleConfigurationChange(engineRunning: Bool, formatMatches: Bool, inputRouteMatches: Bool,
                                   at time: TimeInterval = ProcessInfo.processInfo.systemUptime, generation: Int? = nil) -> ConfigurationAction {
        lock.lock()
        defer { lock.unlock() }
        guard generation == nil || generation == activeGeneration else { return .keepRecording }
        guard writer != nil, failure == nil else { return .failed }
        func fail() -> ConfigurationAction {
            failure = NSError(domain: "AudioCaptureService", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The audio device configuration changed during recording. Recorded audio was preserved. Choose a stable input device and start a new recording."])
            return .failed
        }
        // This fallback is for startup repair only. The service routes actual
        // device/format changes through beginRouteRecovery before calling it.
        // A healthy graph notification alone is not a capture failure.
        guard formatMatches, inputRouteMatches else { return fail() }
        if engineRunning { return .keepRecording }
        guard frameCount == 0, let started = monitoringStartedAt,
              time >= started, time - started <= 5 else { return fail() }
        if startupRestartPending { return .waitForRestart }
        guard !startupRestartUsed else { return fail() }
        startupRestartUsed = true
        startupRestartPending = true
        return .restartEngine
    }

    var canRestartEngine: Bool {
        lock.withLock { writer != nil && failure == nil && frameCount == 0 && startupRestartPending && !startupRestartReserved }
    }

    /// Linearization point for the actual graph restart. This shares the append /
    /// failure lock, so committed frames or failures before reservation forbid it.
    /// The lock is released before AVAudioEngine calls, whose callbacks may reenter.
    func reserveStartupRestart(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard writer != nil, failure == nil, frameCount == 0,
                  startupRestartPending, !startupRestartReserved,
                  let started = monitoringStartedAt, time >= started, time - started <= 5 else { return false }
            startupRestartReserved = true
            startupGenerationCommitted = false
            activeGeneration += 1 // Atomically retire callbacks before any graph work.
            return true
        }
    }

    var generation: Int { lock.withLock { activeGeneration } }
    func acceptsGeneration(_ generation: Int) -> Bool {
        lock.withLock { generation == activeGeneration && writer != nil && failure == nil }
    }
    /// Publish the fresh, non-running graph before start. Its first callback may
    /// synchronously commit during engine.start; retired callbacks remain ignored.
    func commitStartupGeneration(_ generation: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard generation == activeGeneration, writer != nil, failure == nil,
                  frameCount == 0, startupRestartPending, startupRestartReserved,
                  !startupGenerationCommitted, let started = monitoringStartedAt,
                  time >= started, time - started <= 5 else { return false }
            startupGenerationCommitted = true
            return true
        }
    }

    var restartRacedFrames: Bool { lock.withLock { startupRestartRacedFrames } }
    var startupReservationIsValid: Bool {
        lock.withLock { writer != nil && failure == nil && frameCount == 0 && startupRestartPending && startupRestartReserved }
    }

    @discardableResult
    func completeStartupRestart(succeeded: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writer != nil, startupRestartPending else { return false }
        startupRestartPending = false
        startupRestartReserved = false
        if !succeeded, failure == nil {
            failure = NSError(domain: "AudioCaptureService", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The microphone could not start delivering audio. Any saved audio was preserved. Try starting a new recording."])
        }
        // Do not reset monitoringStartedAt: the original five-second frame
        // watchdog still bounds startup even when engine.start() succeeds.
        return succeeded && failure == nil
    }

    /// Retire the old tap before scheduling graph work; committed PCM remains in
    /// the same fixed-format file. Concurrent notifications coalesce here.
    func beginRouteRecovery(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        lock.withLock {
            guard writer != nil, failure == nil, routeRecoveryStartedAt == nil else { return nil }
            routeRecoveryStartedAt = time
            routeNotice = "Microphone changed. Reconnecting; saved audio is preserved."
            startupRestartPending = false
            startupRestartReserved = false
            activeGeneration += 1
            return activeGeneration
        }
    }

    var canRetryRouteRecovery: Bool {
        lock.withLock {
            guard writer != nil, failure == nil, let started = routeRecoveryStartedAt else { return false }
            return ProcessInfo.processInfo.systemUptime - started < 5
        }
    }

    func completeRouteRecovery(succeeded: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard writer != nil, routeRecoveryStartedAt != nil else { return }
            routeRecoveryStartedAt = nil
            if succeeded {
                // Restart is not proof that audio resumed: retain the frame watchdog.
                lastCommittedFrameAt = time
                routeNotice = "Microphone changed. Recording restarted; audio near the device change may contain a short gap."
            } else if failure == nil {
                failure = NSError(domain: "AudioCaptureService", code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone could not reconnect after an audio device change. Recorded audio was preserved. Check your microphone and start a new recording."])
            }
        }
    }

    var captureNotice: String? { lock.withLock { routeNotice } }

    func recordFailure(_ error: Error, generation: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == nil || generation == activeGeneration else { return }
        if failure == nil { failure = error }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        startupRestartPending = false
        startupRestartReserved = false
        routeRecoveryStartedAt = nil
        writer = nil // Close/flush AVAudioFile before consumers decode its URL.
        if let failure { throw failure }
    }

    var bufferHealth: (count: Int, largestSeconds: Double) { lock.withLock { (committedBuffers, largestBufferSeconds) } }
    var duration: Double { lock.withLock { Double(frameCount) / sampleRate } }
    var errorDescription: String? { lock.withLock { failure?.localizedDescription } }
}

public final class AudioCaptureService: @unchecked Sendable {
    public static let shared = AudioCaptureService()
    // lifecycleLock protects start/stop/swap. metricsLock protects published graph
    // identity and metrics. Neither lock crosses a write-state lock + engine call.
    private let lifecycleLock = NSLock()
    private let metricsLock = NSLock()
    private let startupRestartQueue = DispatchQueue(label: "app.minutes.capture-startup-rebuild", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var writeState: CaptureWriteState?
    private var outputURL: URL?
    private var isCapturing = false
    private var level: Float = 0
    private var configurationObserver: NSObjectProtocol?
    private var tapEngine: AVAudioEngine? // lifecycleLock; avoids removing an already retired tap.
    private var diagnostics: CaptureDiagnostics?
    private var observedInputRoutes: [String] = []
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    #endif

    public var currentLevel: Float { metricsLock.withLock { level } }
    public var recordedDuration: Double { metricsLock.withLock { writeState?.duration ?? 0 } }
    public var captureError: String? {
        let (state, graph, diagnostics) = metricsLock.withLock { (writeState, engine, self.diagnostics) }
        state?.checkForStall()
        let failure = state?.errorDescription
        if failure != nil {
            diagnostics?.record(.captureFailed, committedSeconds: state?.duration ?? 0,
                engineRunning: graph?.isRunning ?? false, hasFailure: true)
        }
        return failure
    }
    public var captureNotice: String? { metricsLock.withLock { writeState }?.captureNotice }
    public var capturing: Bool { lifecycleLock.withLock { isCapturing } }
    private init() {}

    public func startRecording(to outputURL: URL) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isCapturing else { throw captureFailure("A recording is already active") }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw captureFailure("Refusing to overwrite existing recording: \(outputURL.lastPathComponent)")
        }
        let diagnostics = CaptureDiagnostics(audioURL: outputURL)
        metricsLock.withLock { self.diagnostics = diagnostics }
        diagnostics.record(.startRequested, committedSeconds: 0, engineRunning: false, hasFailure: false)
        defer {
            if !isCapturing { diagnostics.record(.startFailed, committedSeconds: 0, engineRunning: false, hasFailure: true) }
        }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try configureMicrophoneSession(session)
        } catch {
            diagnostics.record(.startFailed, committedSeconds: 0, engineRunning: false, hasFailure: true,
                failureStage: .sessionActivation, error: error as NSError)
            throw error
        }
        // A new I/O graph is created only after the session has selected hardware.
        let graph = AVAudioEngine()
        #else
        // A stopped graph can retain a previous device format. Start each
        // recording from fresh hardware, just as on iOS.
        let graph = AVAudioEngine()
        #endif
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              nativeFormatIsUsable(graph) else { throw captureFailure("No usable microphone format") }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: pcm.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let state = CaptureWriteState(sampleRate: 16000) { try file.write(from: $0) }
        metricsLock.withLock { engine = graph; writeState = state; level = 0 }
        self.outputURL = outputURL
        recordNativeFormat(of: graph, state: state, diagnostics: diagnostics)
        installNativeTap(on: graph, pcm: pcm, state: state, generation: state.generation)
        do {
            graph.prepare()
            try graph.start()
            isCapturing = true
            state.beginMonitoring()
            let inputRoutes = currentInputRoutes()
            diagnostics.record(.startSucceeded, committedSeconds: state.duration,
                engineRunning: graph.isRunning, hasFailure: state.errorDescription != nil)
            observeConfiguration(of: graph, pcm: pcm, state: state, diagnostics: diagnostics,
                inputRoutes: inputRoutes, generation: state.generation)
        } catch {
            diagnostics.record(.startFailed, committedSeconds: state.duration, engineRunning: graph.isRunning,
                hasFailure: true, failureStage: .engineStart, error: error as NSError)
            removeTap(from: graph)
            graph.stop()
            try state.finish()
            self.outputURL = nil
            throw error
        }
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let snapshot = self.metricsLock.withLock { (self.engine, self.writeState, self.diagnostics) }
            guard let graph = snapshot.0, let state = snapshot.1, let diagnostics = snapshot.2 else { return }
            // Output-only changes (e.g. AirPods connecting while the phone mic
            // stays selected) do not require discarding a healthy input graph.
            let routeMatches = self.currentInputRoutes() == self.metricsLock.withLock { self.observedInputRoutes }
            guard CaptureRoutePolicy.shouldRebuild(engineRunning: graph.isRunning,
                formatMatches: self.nativeFormatIsUsable(graph), inputRouteMatches: routeMatches,
                hasCommittedAudio: true) else { return }
            self.scheduleRouteRecovery(graph, pcm: pcm, state: state, diagnostics: diagnostics)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            state.recordFailure(self.captureFailure("Recording interrupted; preserved audio may contain a gap"))
        }
        #endif
    }

    private func installNativeTap(on graph: AVAudioEngine, pcm: AVAudioFormat, state: CaptureWriteState, generation: Int) {
        let converter = CaptureTapConverter(outputFormat: pcm)
        tapEngine = graph
        // Keep the responsive 1024-frame request. nil leaves I/O in its native
        // format; the converter follows the first actual buffer, never cached I/O.
        graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, state.acceptsGeneration(generation) else { return }
            let measuredLevel = CaptureLevelMeter.displayLevel(rms: CaptureLevelMeter.rms(buffer))
            self.metricsLock.withLock {
                if self.engine === graph, self.writeState === state, state.acceptsGeneration(generation) { self.level = measuredLevel }
            }
            do {
                if let converted = try converter.convert(buffer) { state.append(converted, generation: generation) }
            } catch { state.recordFailure(error, generation: generation) }
        }
    }

    private func observeConfiguration(of graph: AVAudioEngine, pcm: AVAudioFormat, state: CaptureWriteState,
                                      diagnostics: CaptureDiagnostics, inputRoutes: [String], generation: Int) {
        metricsLock.withLock { observedInputRoutes = inputRoutes }
        let expectedFormat = graph.inputNode.outputFormat(forBus: 0)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: nil
        ) { [weak self] _ in
            guard let self, state.acceptsGeneration(generation),
                  self.metricsLock.withLock({ self.engine === graph && self.writeState === state }) else { return }
            let running = graph.isRunning
            let sameFormat = graph.inputNode.outputFormat(forBus: 0).isEqual(expectedFormat)
            let sameRoute = self.currentInputRoutes() == inputRoutes
            if CaptureRoutePolicy.shouldRebuild(engineRunning: running, formatMatches: sameFormat,
                inputRouteMatches: sameRoute, hasCommittedAudio: state.duration > 0) {
                self.scheduleRouteRecovery(graph, pcm: pcm, state: state, diagnostics: diagnostics)
                return
            }
            let action = state.handleConfigurationChange(engineRunning: running, formatMatches: sameFormat,
                inputRouteMatches: sameRoute, generation: generation)
            diagnostics.record(.configurationChecked, committedSeconds: state.duration,
                engineRunning: running, formatMatches: sameFormat, inputRouteMatches: sameRoute,
                hasFailure: state.errorDescription != nil)
            guard action == .restartEngine else { return }
            diagnostics.record(.restartRequested, committedSeconds: state.duration, engineRunning: running,
                formatMatches: sameFormat, inputRouteMatches: sameRoute, hasFailure: false)
            self.startupRestartQueue.async { [weak self] in
                self?.rebuildStartupGraph(graph, pcm: pcm, state: state, diagnostics: diagnostics,
                    inputRoutes: inputRoutes, generation: generation)
            }
        }
    }

    private func rebuildStartupGraph(_ oldGraph: AVAudioEngine, pcm: AVAudioFormat, state: CaptureWriteState,
                                     diagnostics: CaptureDiagnostics, inputRoutes: [String], generation: Int) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard isCapturing, state.acceptsGeneration(generation),
              metricsLock.withLock({ engine === oldGraph && writeState === state }) else { return }
        state.checkForStall()
        guard currentInputRoutes() == inputRoutes else {
            scheduleRouteRecovery(oldGraph, pcm: pcm, state: state, diagnostics: diagnostics)
            return
        }
        if oldGraph.isRunning {
            let healthy = state.completeStartupRestart(succeeded: true)
            diagnostics.record(healthy ? .restartSucceeded : .restartFailed, committedSeconds: state.duration,
                engineRunning: true, hasFailure: !healthy)
            return
        }
        guard state.reserveStartupRestart() else {
            state.completeStartupRestart(succeeded: false)
            diagnostics.record(.restartFailed, committedSeconds: state.duration, engineRunning: false, hasFailure: true)
            return
        }
        let freshGeneration = state.generation // old callbacks are already retired.
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        // Off the graph-notification thread, without any write-state lock held.
        removeTap(from: oldGraph)
        oldGraph.stop()
        var freshGraph = oldGraph
        var formatValid = false
        var routeValid = false
        do {
            _ = try CaptureStartupRestart.run(activateSession: {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
            }, rebuildGraph: {
                #if os(iOS)
                freshGraph = AVAudioEngine()
                #endif
                guard self.nativeFormatIsUsable(freshGraph) else { throw self.captureFailure("No usable native microphone format after activation") }
                self.metricsLock.withLock { self.engine = freshGraph }
                self.recordNativeFormat(of: freshGraph, state: state, diagnostics: diagnostics)
                self.installNativeTap(on: freshGraph, pcm: pcm, state: state, generation: freshGeneration)
                self.observeConfiguration(of: freshGraph, pcm: pcm, state: state, diagnostics: diagnostics,
                    inputRoutes: inputRoutes, generation: freshGeneration)
            }, validateGraph: {
                state.checkForStall()
                // Deliberate startup-only exception: with zero committed frames,
                // the same input device may settle on a different native format.
                // Use that fresh format instead of forcing the retired I/O format.
                // Reservation + original deadline bound this startup adaptation.
                // Later device changes use the separate route-recovery generation.
                formatValid = self.nativeFormatIsUsable(freshGraph)
                routeValid = self.currentInputRoutes() == inputRoutes
                if !formatValid || !routeValid {
                    state.handleConfigurationChange(engineRunning: false, formatMatches: formatValid,
                        inputRouteMatches: routeValid, generation: freshGeneration)
                }
                return formatValid && routeValid && state.commitStartupGeneration(freshGeneration)
            }, prepareAndStart: {
                freshGraph.prepare()
                try freshGraph.start()
                return freshGraph.isRunning
            })
            let healthy = state.completeStartupRestart(succeeded: freshGraph.isRunning)
            diagnostics.record(healthy ? .restartSucceeded : .restartFailed, committedSeconds: state.duration,
                engineRunning: freshGraph.isRunning, formatMatches: formatValid, inputRouteMatches: routeValid,
                hasFailure: !healthy)
        } catch {
            state.completeStartupRestart(succeeded: false)
            let staged = error as? CaptureStartupRestart.Failure
            diagnostics.record(state.restartRacedFrames ? .restartRacedFrames : .restartFailed,
                committedSeconds: state.duration, engineRunning: freshGraph.isRunning,
                formatMatches: formatValid, inputRouteMatches: routeValid, hasFailure: true,
                failureStage: staged?.stage, error: staged?.underlying ?? error as NSError)
        }
    }

    private func scheduleRouteRecovery(_ oldGraph: AVAudioEngine, pcm: AVAudioFormat,
                                       state: CaptureWriteState, diagnostics: CaptureDiagnostics) {
        let generation = metricsLock.withLock { () -> Int? in
            guard engine === oldGraph, writeState === state else { return nil }
            return state.beginRouteRecovery()
        }
        guard let generation else { return }
        diagnostics.record(.restartRequested, committedSeconds: state.duration,
            engineRunning: oldGraph.isRunning, hasFailure: false)
        startupRestartQueue.async { [weak self] in
            self?.rebuildRouteGraph(oldGraph, pcm: pcm, state: state, diagnostics: diagnostics, generation: generation)
        }
    }

    private func rebuildRouteGraph(_ oldGraph: AVAudioEngine, pcm: AVAudioFormat,
                                   state: CaptureWriteState, diagnostics: CaptureDiagnostics, generation: Int) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard isCapturing, state.acceptsGeneration(generation),
              metricsLock.withLock({ engine === oldGraph && writeState === state }) else { return }
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        removeTap(from: oldGraph)
        oldGraph.stop()
        var freshGraph = oldGraph
        do {
            #if os(iOS)
            try configureMicrophoneSession(AVAudioSession.sharedInstance())
            #endif
            freshGraph = AVAudioEngine()
            guard !currentInputRoutes().isEmpty, nativeFormatIsUsable(freshGraph) else {
                throw captureFailure("No microphone is available after the audio device change")
            }
            state.checkForStall()
            guard state.acceptsGeneration(generation) else { throw captureFailure("Microphone recovery timed out") }
            metricsLock.withLock { engine = freshGraph; level = 0 }
            recordNativeFormat(of: freshGraph, state: state, diagnostics: diagnostics)
            installNativeTap(on: freshGraph, pcm: pcm, state: state, generation: generation)
            freshGraph.prepare()
            try freshGraph.start()
            guard freshGraph.isRunning else { throw captureFailure("Microphone did not restart") }
            state.checkForStall()
            guard state.acceptsGeneration(generation) else { throw captureFailure("Microphone recovery timed out") }
            state.completeRouteRecovery(succeeded: true)
            observeConfiguration(of: freshGraph, pcm: pcm, state: state, diagnostics: diagnostics,
                inputRoutes: currentInputRoutes(), generation: generation)
            diagnostics.record(.restartSucceeded, committedSeconds: state.duration,
                engineRunning: true, hasFailure: false)
        } catch {
            removeTap(from: freshGraph)
            freshGraph.stop()
            if state.canRetryRouteRecovery {
                // Device discovery/AVAudioSession may briefly expose zero inputs
                // during a disconnect. Retry off the notification thread, bounded
                // by the original recovery deadline rather than resetting it.
                let publishedGraph = metricsLock.withLock { engine } ?? oldGraph
                startupRestartQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.rebuildRouteGraph(publishedGraph, pcm: pcm, state: state,
                        diagnostics: diagnostics, generation: generation)
                }
            } else {
                state.completeRouteRecovery(succeeded: false)
                diagnostics.record(.restartFailed, committedSeconds: state.duration,
                    engineRunning: false, hasFailure: true, error: error as NSError)
            }
        }
    }

    #if os(iOS)
    private func configureMicrophoneSession(_ session: AVAudioSession) throws {
        // iPhone records the room. Bluetooth HFP opt-in lets an incidental
        // AirPods connection replace that microphone with a headset voice link.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        if let builtIn = CaptureInputDevices.preferredBuiltInMicrophone(in: session) {
            try session.setPreferredInput(builtIn)
        }
    }
    #endif

    private func removeTap(from graph: AVAudioEngine) {
        guard tapEngine === graph else { return }
        graph.inputNode.removeTap(onBus: 0)
        tapEngine = nil
    }

    private func recordNativeFormat(of graph: AVAudioEngine, state: CaptureWriteState, diagnostics: CaptureDiagnostics) {
        let hardware = graph.inputNode.inputFormat(forBus: 0)
        let output = graph.inputNode.outputFormat(forBus: 0)
        #if os(iOS)
        let sessionRate: Double? = AVAudioSession.sharedInstance().sampleRate
        #else
        let sessionRate: Double? = nil
        #endif
        diagnostics.record(.nativeGraphPrepared, committedSeconds: state.duration,
            engineRunning: graph.isRunning, hasFailure: state.errorDescription != nil,
            hardwareSampleRate: hardware.sampleRate, hardwareChannels: Int(hardware.channelCount),
            tapSampleRate: output.sampleRate, tapChannels: Int(output.channelCount), sessionSampleRate: sessionRate)
    }

    private func nativeFormatIsUsable(_ graph: AVAudioEngine) -> Bool {
        let hardware = graph.inputNode.inputFormat(forBus: 0)
        let output = graph.inputNode.outputFormat(forBus: 0)
        return hardware.sampleRate > 0 && hardware.channelCount > 0 &&
            hardware.sampleRate == output.sampleRate && hardware.channelCount == output.channelCount
    }

    private func currentInputRoutes() -> [String] {
        CaptureInputDevices.routeIdentifiers()
    }

    public func stopRecording() throws -> URL? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard isCapturing, let graph = metricsLock.withLock({ engine }) else { return nil }
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        let (state, diagnostics) = metricsLock.withLock { (writeState, self.diagnostics) }
        state?.checkForStall()
        removeTap(from: graph)
        graph.stop()
        isCapturing = false
        let url = outputURL
        outputURL = nil
        metricsLock.withLock { level = 0 }
        let finalization = Result { try state?.finish() }
        let bufferHealth = state?.bufferHealth
        diagnostics?.record(.stopped, committedSeconds: state?.duration ?? 0,
            engineRunning: graph.isRunning, hasFailure: state?.errorDescription != nil,
            committedBufferCount: bufferHealth?.count, largestBufferSeconds: bufferHealth?.largestSeconds)
        #if os(iOS)
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = nil
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
        routeObserver = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        try finalization.get()
        return url
    }

    private func captureFailure(_ message: String) -> NSError {
        NSError(domain: "AudioCaptureService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
