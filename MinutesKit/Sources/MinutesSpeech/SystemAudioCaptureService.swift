#if os(macOS)
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

@MainActor public protocol SystemAudioRecording: AnyObject {
    var captureError: String? { get }
    var capturing: Bool { get }
    /// The latest device change the recording recovered from, for the UI.
    var recoveryNotice: String? { get }
    func startRecording(to directory: URL, includeMicrophone: Bool) async throws
    func stopRecording() async throws -> SynchronizedCaptureResult
}

/// Starts only on an explicit call, after permissions have already been granted.
/// One SCStream provides system and microphone timestamps in its shared clock.
@MainActor public final class SystemAudioCaptureService: SystemAudioRecording {
    private var stream: SCStream?
    private var output: CaptureStreamOutput?
    private var archive: SynchronizedCaptureArchive?
    private let queue = DispatchQueue(label: "Minutes.SystemAudioCapture", qos: .userInitiated)
    private var transitioning = false
    public private(set) var capturing = false
    public private(set) var recordingDirectory: URL?
    public var captureError: String? { archive?.errorDescription }
    public private(set) var recoveryNotice: String?
    /// The person asked for the microphone; it may be temporarily absent.
    private var wantsMicrophone = false
    private var microphoneActive = false
    private var microphoneName: String?
    private var display: SCDisplay?
    private var monitor: Task<Void, Never>?
    private var streamStopped = false
    private var restartFailures = 0
    private var lastRestart = Date.distantPast
    public init() {}

    public func startRecording(to directory: URL, includeMicrophone: Bool = true) async throws {
        guard !capturing, !transitioning, stream == nil else { throw SynchronizedCaptureArchive.failure("A system recording is already active or changing state.") }
        guard CGPreflightScreenCaptureAccess() else {
            throw SynchronizedCaptureArchive.failure("Allow Minutes in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Minutes if macOS requests it. Recording has not started.")
        }
        if includeMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw SynchronizedCaptureArchive.failure("Allow microphone access before starting system + microphone capture.")
        }
        if includeMicrophone && AVCaptureDevice.default(for: .audio) == nil {
            throw SynchronizedCaptureArchive.failure("No microphone input device is available. Select an input in System Settings > Sound, then start a new recording.")
        }
        transitioning = true
        defer { transitioning = false }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SynchronizedCaptureArchive.failure("No shareable display is available for system audio capture.") }
        let archive = try SynchronizedCaptureArchive(directory: directory, includeMicrophone: includeMicrophone)
        self.archive = archive
        self.display = display
        recordingDirectory = directory
        wantsMicrophone = includeMicrophone
        recoveryNotice = nil
        restartFailures = 0
        do {
            try await openStream(archive: archive)
            capturing = true
            startMonitoring()
        } catch {
            archive.recordFailure("System capture could not start: \(error.localizedDescription)")
            self.stream = nil
            self.output = nil
            _ = try? archive.finish()
            throw error
        }
    }

    /// One SCStream for Mac audio and, when available, the current default microphone.
    /// Restarts reuse the same archive, so the recording continues on the same clock.
    private func openStream(archive: SynchronizedCaptureArchive) async throws {
        guard let display else { throw SynchronizedCaptureArchive.failure("No shareable display is available for system audio capture.") }
        let microphone = wantsMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? AVCaptureDevice.default(for: .audio) : nil
        let output = CaptureStreamOutput(archive: archive) { [weak self] in
            Task { @MainActor in self?.streamStopped = true }
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = microphone != nil
        // Bind to the chosen device; a later route change is handled by restarting
        // with the then-current device rather than silently mixing devices.
        if let microphone { configuration.microphoneCaptureDeviceID = microphone.uniqueID }
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        if microphone != nil { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        self.output = output
        try await stream.startCapture()
        streamStopped = false
        microphoneActive = microphone != nil
        microphoneName = microphone?.localizedName
    }

    /// Watches for a stopped stream, a microphone that stopped delivering, or a
    /// microphone that came back, and restarts capture to follow the change.
    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.capturing, !self.transitioning, let archive = self.archive else { continue }
                if archive.errorDescription != nil { return }
                // A restarted source needs a moment to deliver before its old gap stops counting as a stall.
                let settled = Date().timeIntervalSince(self.lastRestart) > 6
                let stalled = settled ? archive.stalledSource(ignoringMicrophone: !self.microphoneActive) : nil
                let microphoneReturned = settled && self.wantsMicrophone && !self.microphoneActive && AVCaptureDevice.default(for: .audio) != nil
                guard self.streamStopped || stalled != nil || microphoneReturned else { continue }
                // Back off between attempts; give up after repeated failures.
                guard Date().timeIntervalSince(self.lastRestart) >= min(8, pow(2, Double(self.restartFailures))) else { continue }
                await self.restart(reason: self.streamStopped ? "stream" : (stalled == .microphone ? "microphone" : (stalled == .system ? "system" : "returned")))
            }
        }
    }

    private func restart(reason: String) async {
        guard let archive, capturing, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        lastRestart = Date()
        let previousMicrophone = microphoneName
        if let stream { try? await stream.stopCapture() }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        stream = nil; output = nil
        do {
            try await openStream(archive: archive)
            restartFailures = 0
            let notice: String
            if wantsMicrophone && !microphoneActive {
                notice = "\(previousMicrophone ?? "The microphone") isn't available, so Minutes is recording Mac audio only until a microphone returns."
            } else if reason == "returned" || previousMicrophone != microphoneName, let microphoneName {
                notice = previousMicrophone == nil ? "Microphone is back: recording \(microphoneName) again." : "\(previousMicrophone ?? "The microphone") disconnected; now recording \(microphoneName)."
            } else {
                notice = "Recording paused briefly and resumed."
            }
            recoveryNotice = notice
            archive.recordInterruption(notice)
        } catch {
            restartFailures += 1
            recoveryNotice = "Trying to resume recording… (\(error.localizedDescription))"
            if restartFailures >= 5 {
                archive.requestStop("Recording stopped because audio capture could not be restarted after a device change.")
            }
        }
    }

    public func stopRecording() async throws -> SynchronizedCaptureResult {
        guard !transitioning, let archive else { throw SynchronizedCaptureArchive.failure("No system recording is ready to stop.") }
        monitor?.cancel(); monitor = nil
        transitioning = true
        defer { transitioning = false; capturing = false; stream = nil; output = nil; display = nil }
        if let stream {
            do { try await stream.stopCapture() }
            catch { archive.recordFailure("System capture could not stop cleanly: \(error.localizedDescription)") }
        }
        // Drain all queued callbacks before closing source files and rendering.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        return try await Task.detached(priority: .userInitiated) { try archive.finish() }.value
    }
}

/// Framework delegate callbacks are serialized by `queue`; archive state is locked.
final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let archive: SynchronizedCaptureArchive
    private let onStop: @Sendable () -> Void
    init(archive: SynchronizedCaptureArchive, onStop: @escaping @Sendable () -> Void = {}) { self.archive = archive; self.onStop = onStop }

    /// A device change (for example AirPods moving to another device) stops the
    /// stream; the service restarts it, so this is not a recording failure.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handleSampleBuffer(sampleBuffer, type: type)
    }

    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        // ScreenCaptureKit can send unavailable/empty callbacks while a source
        // starts. These carry no audio; only malformed ready PCM or real stream
        // errors should stop a recording. Finalization still requires both tracks.
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd) else {
                throw SynchronizedCaptureArchive.failure("The \(type == .microphone ? "microphone" : "system") stream returned an invalid PCM format.")
            }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, frames <= Int(Int32.max),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw SynchronizedCaptureArchive.failure("The system stream returned an invalid audio buffer size.")
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw SynchronizedCaptureArchive.failure("Cannot copy captured PCM audio (OSStatus \(status)).") }
            try archive.append(pcm, source: type == .audio ? .system : .microphone,
                               presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } catch { archive.recordFailure(error.localizedDescription) }
    }
}
#endif
