import Foundation

/// Bounded, content-free capture lifecycle evidence. Never stores audio, route IDs,
/// error descriptions, file paths, transcript text or device names in the payload.
final class CaptureDiagnostics: @unchecked Sendable {
    enum Event: String, Codable, Sendable {
        case startRequested, startSucceeded, startFailed, configurationChecked, captureFailed, stopped
        case restartRequested, restartSucceeded, restartFailed, restartRacedFrames, nativeGraphPrepared
    }
    struct Entry: Codable, Sendable {
        let event: Event
        let uptime: Double
        let committedSeconds: Double
        let engineRunning: Bool
        let formatMatches: Bool?
        let inputRouteMatches: Bool?
        let hasFailure: Bool
        let failureStage: CaptureStartupRestart.Stage?
        let errorDomain: String?
        let errorCode: Int?
        let hardwareSampleRate: Double?
        let hardwareChannels: Int?
        let tapSampleRate: Double?
        let tapChannels: Int?
        let sessionSampleRate: Double?
        let committedBufferCount: Int?
        let largestBufferSeconds: Double?
    }
    private let queue = DispatchQueue(label: "app.minutes.capture-diagnostics", qos: .utility)
    private let url: URL
    private var entries: [Entry] = [] // Confined to queue.
    private var recordedCaptureFailure = false

    init(audioURL: URL) { url = audioURL.appendingPathExtension("capture-diagnostics.json") }

    func record(_ event: Event, committedSeconds: Double, engineRunning: Bool,
                formatMatches: Bool? = nil, inputRouteMatches: Bool? = nil, hasFailure: Bool,
                failureStage: CaptureStartupRestart.Stage? = nil, error: NSError? = nil,
                hardwareSampleRate: Double? = nil, hardwareChannels: Int? = nil,
                tapSampleRate: Double? = nil, tapChannels: Int? = nil, sessionSampleRate: Double? = nil,
                committedBufferCount: Int? = nil, largestBufferSeconds: Double? = nil) {
        let entry = Entry(event: event, uptime: ProcessInfo.processInfo.systemUptime,
            committedSeconds: committedSeconds, engineRunning: engineRunning,
            formatMatches: formatMatches, inputRouteMatches: inputRouteMatches, hasFailure: hasFailure,
            failureStage: failureStage, errorDomain: error?.domain, errorCode: error?.code,
            hardwareSampleRate: hardwareSampleRate, hardwareChannels: hardwareChannels,
            tapSampleRate: tapSampleRate, tapChannels: tapChannels, sessionSampleRate: sessionSampleRate,
            committedBufferCount: committedBufferCount, largestBufferSeconds: largestBufferSeconds)
        queue.async { [self] in
            if event == .captureFailed {
                guard !recordedCaptureFailure else { return }
                recordedCaptureFailure = true
            }
            entries.append(entry)
            if entries.count > 16 { entries.removeFirst(entries.count - 16) }
            // Diagnostic failure must not fail a working recorder. The audio writer
            // independently reports disk errors through CaptureWriteState.
            if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
        }
    }

    func waitForPendingWrites() { queue.sync {} } // Deterministic test boundary.
}
