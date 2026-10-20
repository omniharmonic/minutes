import Foundation
import AVFoundation
import CoreMedia

public enum CaptureAudioSource: String, Codable, Sendable { case system, microphone }

public struct SynchronizedCaptureResult: Sendable {
    public let directory: URL
    /// Original source audio at each device's native rate and channel layout.
    public let systemAudioURL: URL
    public let microphoneURL: URL?
    /// Only populated after successful timestamp alignment and mixing.
    public let processingURL: URL?
    public let manifestURL: URL
    public let duration: Double
    public let issues: [String]
    /// Gaps and missing sources that were filled with silence; the recording is still usable.
    public let interruptions: [String]

    public init(directory: URL, systemAudioURL: URL, microphoneURL: URL?, processingURL: URL?,
                manifestURL: URL, duration: Double, issues: [String], interruptions: [String] = []) {
        self.directory = directory
        self.systemAudioURL = systemAudioURL
        self.microphoneURL = microphoneURL
        self.processingURL = processingURL
        self.manifestURL = manifestURL
        self.duration = duration
        self.issues = issues
        self.interruptions = interruptions
    }
}

public struct CaptureFinalizationError: Error, LocalizedError, Sendable {
    public let result: SynchronizedCaptureResult
    public init(result: SynchronizedCaptureResult) { self.result = result }
    public var errorDescription: String? {
        "Capture could not be completed. Source audio is preserved at \(result.directory.path). " + result.issues.joined(separator: "; ")
    }
}

struct CaptureTimelineSegment: Codable, Sendable {
    let sourceFrame: Int64
    var frameCount: Int64
    let presentationTime: Double
}

struct CaptureTrackTimeline: Codable, Sendable {
    let source: CaptureAudioSource
    let file: String
    let sampleRate: Double
    let channels: UInt32
    var frameCount: Int64
    var segments: [CaptureTimelineSegment]
}

struct CaptureTimelineManifest: Codable, Sendable {
    let schema: String
    let clock: String
    let startedAt: Date
    let completed: Bool
    let processingFile: String?
    let timelineOrigin: Double?
    let duration: Double
    let tracks: [CaptureTrackTimeline]
    let issues: [String]
    var interruptions: [String]? = nil
}

private final class CaptureSourceWriter {
    let format: AVAudioFormat
    var file: AVAudioFile?
    var timeline: CaptureTrackTimeline
    /// Converts a replacement device's audio (another rate or layout) into `format`.
    var converter: (input: AVAudioFormat, converter: AVAudioConverter)?

    init(source: CaptureAudioSource, directory: URL, format: AVAudioFormat) throws {
        self.format = format
        let name = source == .system ? "system.caf" : "microphone.caf"
        file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings,
                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        timeline = CaptureTrackTimeline(source: source, file: name, sampleRate: format.sampleRate,
                                        channels: format.channelCount, frameCount: 0, segments: [])
    }
}

/// Thread-safe disk boundary shared by the two ScreenCaptureKit output types.
/// The framework callbacks use a single serial queue; the lock also protects
/// error/status reads from the app's executor. No audio devices are opened here.
final class SynchronizedCaptureArchive: @unchecked Sendable {
    let directory: URL
    private let includeMicrophone: Bool
    private let lock = NSLock()
    private var writers: [CaptureAudioSource: CaptureSourceWriter] = [:]
    /// Fatal problems: the recording cannot be saved as audio.
    private var issues: [String] = []
    /// Device changes, gaps and missing sources: saved, disclosed, still processed.
    private var interruptions: [String] = []
    private var finished = false
    private var finishedResult: SynchronizedCaptureResult?
    private let startedAt = Date()
    private var lastCheckpoint = Date.distantPast

    init(directory: URL, includeMicrophone: Bool) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw Self.failure("Choose a new recording directory; an existing directory will not be overwritten.")
        }
        self.directory = directory
        self.includeMicrophone = includeMicrophone
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkpoint(completed: false, processingFile: nil)
    }

    /// Asks the app to end the recording; what was captured is still mixed and processed.
    private var stopReason: String?
    /// Fatal problems, or a requested stop, end a recording; device changes are handled by restarting capture.
    var errorDescription: String? { lock.withLock { issues.first ?? stopReason } }

    func requestStop(_ reason: String) {
        lock.withLock { if stopReason == nil { stopReason = reason } }
    }

    /// A source whose clock coverage has fallen behind the other one's by more than
    /// `grace` seconds (amplitude is not used: a silent input is healthy).
    func stalledSource(grace: Double = 3.0, ignoringMicrophone: Bool = false) -> CaptureAudioSource? {
        lock.withLock {
            guard includeMicrophone, !finished else { return nil }
            for source in [CaptureAudioSource.microphone, .system] where !(ignoringMicrophone && source == .microphone) {
                let peer: CaptureAudioSource = source == .microphone ? .system : .microphone
                if ignoringMicrophone && peer == .microphone { continue }
                guard let peerTrack = writers[peer]?.timeline,
                      let peerStart = peerTrack.segments.first?.presentationTime,
                      let peerLast = peerTrack.segments.last else { continue }
                let peerEnd = peerLast.presentationTime + Double(peerLast.frameCount) / peerTrack.sampleRate
                let sourceEnd: Double
                if let track = writers[source]?.timeline, let last = track.segments.last {
                    sourceEnd = last.presentationTime + Double(last.frameCount) / track.sampleRate
                } else {
                    sourceEnd = peerStart
                }
                if peerEnd - sourceEnd > grace + 0.000_001 { return source }
            }
            return nil
        }
    }

    func recordInterruption(_ message: String) {
        lock.withLock {
            if !interruptions.contains(message) { interruptions.append(message) }
            try? checkpoint(completed: false, processingFile: nil)
        }
    }

    func recordFailure(_ message: String) {
        lock.withLock { if !issues.contains(message) { issues.append(message) } }
    }

    func append(_ buffer: AVAudioPCMBuffer, source: CaptureAudioSource, presentationTime: CMTime) throws {
        try lock.withLock {
            guard !finished else { throw Self.failure("The recording has already been finalized.") }
            guard issues.isEmpty else { throw Self.failure(issues[0]) }
            do {
                guard source != .microphone || includeMicrophone else { throw Self.failure("Unexpected microphone samples in a system-only capture.") }
                let time = presentationTime.seconds
                guard presentationTime.isValid, time.isFinite, time >= 0,
                      buffer.frameLength > 0, buffer.format.sampleRate.isFinite,
                      buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
                    throw Self.failure("Invalid capture audio format or sample timestamp.")
                }
                if let channels = buffer.floatChannelData {
                    let count = buffer.format.isInterleaved ? Int(buffer.frameLength * buffer.format.channelCount) : Int(buffer.frameLength)
                    let channelCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
                    for c in 0..<channelCount {
                        guard UnsafeBufferPointer(start: channels[c], count: count).allSatisfy(\.isFinite) else {
                            throw Self.failure("The audio source returned non-finite samples.")
                        }
                    }
                }
                let writer: CaptureSourceWriter
                if let existing = writers[source] { writer = existing }
                else {
                    writer = try CaptureSourceWriter(source: source, directory: directory, format: buffer.format)
                    writers[source] = writer
                }
                // A replacement microphone can use another rate or layout; convert
                // it to the track's format rather than ending the recording.
                let buffer = try Self.conform(buffer, to: writer)
                let count = Int64(buffer.frameLength)
                guard count > 0 else { return }
                var continuous = false
                if let previous = writer.timeline.segments.last {
                    let previousEnd = previous.presentationTime + Double(previous.frameCount) / writer.timeline.sampleRate
                    let difference = time - previousEnd
                    guard difference >= -1.1 / writer.timeline.sampleRate else {
                        throw Self.failure("The \(source.rawValue) audio clock moved backwards or overlapped.")
                    }
                    continuous = abs(difference) <= 1.1 / writer.timeline.sampleRate
                }
                guard let file = writer.file else { throw Self.failure("Audio source file is closed.") }
                try file.write(from: buffer)
                CaptionAudioFeed.shared.offer(buffer, source: source == .system ? "Mac audio" : "Microphone")
                if continuous {
                    writer.timeline.segments[writer.timeline.segments.count - 1].frameCount += count
                } else {
                    writer.timeline.segments.append(CaptureTimelineSegment(sourceFrame: writer.timeline.frameCount,
                                                                            frameCount: count, presentationTime: time))
                }
                writer.timeline.frameCount += count
                // Small, coalesced timing checkpoints keep raw audio recoverable
                // without serializing every callback throughout a long meeting.
                if Date().timeIntervalSince(lastCheckpoint) >= 1 {
                    try checkpoint(completed: false, processingFile: nil)
                    lastCheckpoint = Date()
                }
            } catch {
                if !issues.contains(error.localizedDescription) { issues.append(error.localizedDescription) }
                throw error
            }
        }
    }

    func finish() throws -> SynchronizedCaptureResult {
        try lock.withLock {
            if let result = finishedResult {
                if result.processingURL == nil { throw CaptureFinalizationError(result: result) }
                return result
            }
            finished = true
            for writer in writers.values { writer.file = nil }
            if let stopReason, !interruptions.contains(stopReason) { interruptions.append(stopReason) }
            let hasSystem = writers[.system]?.timeline.frameCount ?? 0 > 0
            let hasMicrophone = writers[.microphone]?.timeline.frameCount ?? 0 > 0
            if !hasSystem && !hasMicrophone {
                issues.append("No audio was captured. Check Screen & System Audio Recording permission and the microphone.")
            } else {
                if !hasSystem { interruptions.append("No Mac audio was captured; the recording has your microphone only.") }
                if includeMicrophone && !hasMicrophone { interruptions.append("No microphone audio was captured; the recording has Mac audio only.") }
                interruptions.append(contentsOf: coverageIssues())
            }
            var processing: URL?
            if issues.isEmpty {
                do {
                    // Gaps become silence and are listed in `interruptions`.
                    let tracks = timelines().filter { $0.frameCount > 0 }
                    processing = try autoreleasepool { try CaptureTimelineRenderer.render(directory: directory, tracks: tracks) }
                } catch { issues.append("Audio alignment/mixing failed: \(error.localizedDescription)") }
            }
            do { try checkpoint(completed: issues.isEmpty, processingFile: issues.isEmpty ? processing?.lastPathComponent : nil) }
            catch { issues.append("Capture manifest could not be finalized: \(error.localizedDescription)") }
            let result = SynchronizedCaptureResult(directory: directory,
                systemAudioURL: directory.appendingPathComponent("system.caf"),
                microphoneURL: includeMicrophone ? directory.appendingPathComponent("microphone.caf") : nil,
                processingURL: issues.isEmpty ? processing : nil,
                manifestURL: directory.appendingPathComponent("capture.json"),
                duration: bounds().duration, issues: issues, interruptions: interruptions)
            finishedResult = result
            if result.processingURL == nil { throw CaptureFinalizationError(result: result) }
            return result
        }
    }

    /// Converts a buffer from a replacement device into the writer's format.
    private static func conform(_ buffer: AVAudioPCMBuffer, to writer: CaptureSourceWriter) throws -> AVAudioPCMBuffer {
        let target = writer.format
        if buffer.format.sampleRate == target.sampleRate, buffer.format.channelCount == target.channelCount,
           buffer.format.commonFormat == target.commonFormat, buffer.format.isInterleaved == target.isInterleaved { return buffer }
        if writer.converter?.input != buffer.format {
            guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
                throw failure("The replacement audio device uses a format that cannot be converted.")
            }
            converter.downmix = true
            writer.converter = (buffer.format, converter)
        }
        let converter = writer.converter!.converter
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw failure("Cannot allocate conversion buffer.") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? failure("Audio conversion failed.") }
        return output
    }

    /// Callback timestamps establish coverage, even when the samples themselves are silent.
    /// Allow bounded device startup/shutdown skew and short transport gaps; never
    /// hide a stopped source by padding the remainder of a meeting with silence.
    private func coverageIssues() -> [String] {
        let tracks = timelines()
        let timing = bounds()
        guard let origin = timing.origin else { return [] }
        let end = origin + timing.duration
        // These are absolute time budgets, not percentages that grow with a meeting.
        // The existing 100 ms source-offset and 10 ms gap alignment remain valid.
        let edgeTolerance = 1.0
        let gapTolerance = 0.25
        let roundingTolerance = 0.000_001
        var failures: [String] = []
        for track in tracks {
            guard let first = track.segments.first, let last = track.segments.last else { continue }
            let name = track.source == .microphone ? "Microphone" : "Mac"
            func clock(_ seconds: Double) -> String {
                let total = max(0, Int(seconds.rounded())); return String(format: "%d:%02d", total / 60, total % 60)
            }
            let leading = max(0, first.presentationTime - origin)
            let lastEnd = last.presentationTime + Double(last.frameCount) / track.sampleRate
            let trailing = max(0, end - lastEnd)
            if leading > edgeTolerance + roundingTolerance {
                failures.append("\(name) audio started at \(clock(leading)).")
            }
            var shortGaps = 0.0
            for (previous, next) in zip(track.segments, track.segments.dropFirst()) {
                let previousEnd = previous.presentationTime + Double(previous.frameCount) / track.sampleRate
                let gap = max(0, next.presentationTime - previousEnd)
                if gap > gapTolerance + roundingTolerance {
                    failures.append("\(name) audio is missing from \(clock(previousEnd - origin)) to \(clock(next.presentationTime - origin)).")
                } else { shortGaps += gap }
            }
            // Many brief dropouts can add up; disclose them too.
            if shortGaps > 1.0 + roundingTolerance {
                failures.append("\(name) audio has brief dropouts totaling \(String(format: "%.1f", shortGaps)) seconds.")
            }
            if trailing > edgeTolerance + roundingTolerance {
                failures.append("\(name) audio stopped at \(clock(lastEnd - origin)).")
            }
        }
        return failures
    }

    private func timelines() -> [CaptureTrackTimeline] {
        writers.values.map(\.timeline).sorted { $0.source.rawValue < $1.source.rawValue }
    }

    private func bounds() -> (origin: Double?, duration: Double) {
        let tracks = timelines()
        guard let origin = tracks.compactMap({ $0.segments.first?.presentationTime }).min() else { return (nil, 0) }
        let end = tracks.flatMap { track in
            track.segments.map { $0.presentationTime + Double($0.frameCount) / track.sampleRate }
        }.max() ?? origin
        return (origin, max(0, end - origin))
    }

    private func checkpoint(completed: Bool, processingFile: String?) throws {
        let timing = bounds()
        let manifest = CaptureTimelineManifest(schema: "minutes.capture/1", clock: "SCStream.synchronizationClock",
            startedAt: startedAt, completed: completed, processingFile: processingFile,
            timelineOrigin: timing.origin, duration: timing.duration, tracks: timelines(), issues: issues,
            interruptions: interruptions.isEmpty ? nil : interruptions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Minutes.SystemCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Offline rendering uses bounded audio buffers, retaining both original source
/// files. Timestamp gaps become silence; no acoustically inferred offsets are
/// substituted for the framework's recorded clock values.
private enum CaptureTimelineRenderer {
    static let rate = 48_000.0
    static let blockSize: AVAudioFrameCount = 4096

    static func render(directory: URL, tracks: [CaptureTrackTimeline]) throws -> URL {
        guard let origin = tracks.compactMap({ $0.segments.first?.presentationTime }).min(),
              let end = tracks.flatMap({ track in track.segments.map { $0.presentationTime + Double($0.frameCount) / track.sampleRate } }).max(),
              end > origin, end - origin <= 86_400,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw SynchronizedCaptureArchive.failure("Invalid or excessively long capture timeline.")
        }
        let frameCount = Int64(((end - origin) * rate).rounded())
        var aligned: [URL] = []
        for track in tracks {
            let normalized = directory.appendingPathComponent(".normalized-\(track.source.rawValue).caf")
            defer { try? FileManager.default.removeItem(at: normalized) }
            do { try autoreleasepool { try normalize(source: directory.appendingPathComponent(track.file), destination: normalized, format: format) } } catch { throw SynchronizedCaptureArchive.failure("Normalize: \(error)") }
            let alignedURL = directory.appendingPathComponent("aligned-\(track.source.rawValue).caf")
            try autoreleasepool {
                try align(normalized: normalized, destination: alignedURL, track: track, origin: origin,
                          totalFrames: frameCount, format: format)
            }
            aligned.append(alignedURL)
        }
        let destination = directory.appendingPathComponent("mixed.caf")
        try mix(aligned: aligned, destination: destination, totalFrames: frameCount, format: format)
        return destination
    }

    private static func normalize(source: URL, destination: URL, format: AVAudioFormat) throws {
        let input = try AVAudioFile(forReading: source)
        if input.processingFormat == format {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: format.settings)
        defer { output = nil }
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: blockSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
            throw SynchronizedCaptureArchive.failure("Cannot create source audio converter.")
        }
        converter.primeMethod = .none
        converter.downmix = true
        while true {
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
                do {
                    if input.framePosition >= input.length { inputStatus.pointee = .endOfStream; return nil }
                    try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(Int64(blockSize), Int64(requested), input.length - input.framePosition)))
                    if inputBuffer.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                } catch { readError = error; inputStatus.pointee = .noDataNow; return nil }
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? SynchronizedCaptureArchive.failure("Source resampling failed.") }
            if outputBuffer.frameLength > 0 { try output?.write(from: outputBuffer) }
            if status == .endOfStream { break }
            if outputBuffer.frameLength == 0 { throw SynchronizedCaptureArchive.failure("Source resampling made no progress.") }
        }
    }

    private static func align(normalized: URL, destination: URL, track: CaptureTrackTimeline,
                              origin: Double, totalFrames: Int64, format: AVAudioFormat) throws {
        let input = try AVAudioFile(forReading: normalized)
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { throw SynchronizedCaptureArchive.failure("Cannot allocate alignment buffer.") }
        var written: Int64 = 0
        for segment in track.segments {
            var target = Int64(((segment.presentationTime - origin) * rate).rounded())
            var source = Int64((Double(segment.sourceFrame) * rate / track.sampleRate).rounded())
            let sourceEnd = Int64((Double(segment.sourceFrame + segment.frameCount) * rate / track.sampleRate).rounded())
            if target < written {
                guard written - target <= 2 else { throw SynchronizedCaptureArchive.failure("Overlapping source timing cannot be aligned safely.") }
                source += written - target
                target = written
            }
            try silence(output: output, buffer: buffer, frames: target - written)
            written = target
            input.framePosition = min(source, input.length)
            var remaining = max(0, min(sourceEnd, input.length) - source)
            while remaining > 0 {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(blockSize), remaining)))
                guard buffer.frameLength > 0 else { throw SynchronizedCaptureArchive.failure("A source file ended before its timing metadata.") }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
                written += Int64(buffer.frameLength)
            }
            if sourceEnd > input.length + 2 { throw SynchronizedCaptureArchive.failure("Source audio duration does not match capture timestamps.") }
        }
        guard written <= totalFrames + 2 else { throw SynchronizedCaptureArchive.failure("Aligned source exceeds the shared timeline.") }
        try silence(output: output, buffer: buffer, frames: max(0, totalFrames - written))
    }

    private static func silence(output: AVAudioFile, buffer: AVAudioPCMBuffer, frames: Int64) throws {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(blockSize), remaining))
            buffer.frameLength = count
            buffer.floatChannelData![0].update(repeating: 0, count: Int(count))
            try output.write(from: buffer)
            remaining -= Int64(count)
        }
    }

    private static func mix(aligned: [URL], destination: URL, totalFrames: Int64, format: AVAudioFormat) throws {
        let sources = try aligned.map { try AVAudioFile(forReading: $0) }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let buffers = try sources.map { _ -> AVAudioPCMBuffer in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { throw SynchronizedCaptureArchive.failure("Cannot allocate mix buffer.") }
            return buffer
        }
        guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize), !sources.isEmpty else {
            throw SynchronizedCaptureArchive.failure("No sources to mix.")
        }
        var remaining = totalFrames
        let gain = 1 / Float(sources.count)
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(blockSize), remaining))
            mixed.frameLength = count
            mixed.floatChannelData![0].update(repeating: 0, count: Int(count))
            for (index, source) in sources.enumerated() {
                try source.read(into: buffers[index], frameCount: count)
                guard buffers[index].frameLength == count else { throw SynchronizedCaptureArchive.failure("Aligned audio is incomplete.") }
                for f in 0..<Int(count) { mixed.floatChannelData![0][f] += buffers[index].floatChannelData![0][f] * gain }
            }
            for f in 0..<Int(count) { mixed.floatChannelData![0][f] = min(1, max(-1, mixed.floatChannelData![0][f])) }
            try output.write(from: mixed)
            remaining -= Int64(count)
        }
    }
}
