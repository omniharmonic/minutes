#if os(macOS)
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

@MainActor public protocol SystemAudioRecording: AnyObject {
    var captureError: String? { get }
    var capturing: Bool { get }
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
    public init() {}

    public func startRecording(to directory: URL, includeMicrophone: Bool = true) async throws {
        guard !capturing, !transitioning, stream == nil else { throw SynchronizedCaptureArchive.failure("A system recording is already active or changing state.") }
        guard CGPreflightScreenCaptureAccess() else {
            throw SynchronizedCaptureArchive.failure("Allow Minutes in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Minutes if macOS requests it. Recording has not started.")
        }
        if includeMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw SynchronizedCaptureArchive.failure("Allow microphone access before starting system + microphone capture.")
        }
        let microphoneDeviceID: String?
        if includeMicrophone {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw SynchronizedCaptureArchive.failure("No microphone input device is available. Select an input in System Settings > Sound, then start a new recording.")
            }
            microphoneDeviceID = microphone.uniqueID
        } else { microphoneDeviceID = nil }
        transitioning = true
        defer { transitioning = false }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SynchronizedCaptureArchive.failure("No shareable display is available for system audio capture.") }
        let archive = try SynchronizedCaptureArchive(directory: directory, includeMicrophone: includeMicrophone)
        self.archive = archive
        recordingDirectory = directory
        let output = CaptureStreamOutput(archive: archive)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = includeMicrophone
        // Bind this recording to the selected device instead of silently following
        // default-input route changes (for example an AirPods disconnect).
        if let microphoneDeviceID { configuration.microphoneCaptureDeviceID = microphoneDeviceID }
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            if includeMicrophone { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue) }
            self.stream = stream
            self.output = output
            try await stream.startCapture()
            capturing = true
        } catch {
            archive.recordFailure("System capture could not start: \(error.localizedDescription)")
            self.stream = nil
            self.output = nil
            _ = try? archive.finish()
            throw error
        }
    }

    public func stopRecording() async throws -> SynchronizedCaptureResult {
        guard !transitioning, let archive else { throw SynchronizedCaptureArchive.failure("No system recording is ready to stop.") }
        transitioning = true
        defer { transitioning = false; capturing = false; stream = nil; output = nil }
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
    init(archive: SynchronizedCaptureArchive) { self.archive = archive }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        archive.recordFailure("System capture stopped unexpectedly: \(error.localizedDescription)")
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
