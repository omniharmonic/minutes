import Foundation
import AVFoundation
import MinutesCore

public enum SpeakerClipError: Error, Sendable, Equatable, LocalizedError {
    /// The cluster has no utterance with usable start and end times.
    case noTimedUtterances
    /// The meeting has no recorded audio, or the file the review screen would play is gone.
    case audioUnavailable(String)
    /// Reading or encoding the audio failed.
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noTimedUtterances: "This speaker has no timed utterances to clip."
        case .audioUnavailable(let message): message
        case .encodingFailed(let message): "The clip could not be written: \(message)"
        }
    }
}

/// A short excerpt of one speaker cluster, written as AAC for someone to listen
/// to elsewhere (the control API's `clip`). Selection is pure (`plan`); audio
/// comes from the same file the speaker review screen plays (`SpeakerAudioSample.audioPath`).
public enum SpeakerClip {
    public struct Segment: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
        public var duration: Double { end - start }
    }

    public struct Output: Sendable, Equatable {
        public let url: URL
        public let duration: Double
        public let segments: [Segment]
    }

    public static let defaultMaxSeconds = 10.0
    public static let allowedMaxSeconds: ClosedRange<Double> = 3...20
    public static let gapSeconds = 0.25
    public static let retention: TimeInterval = 7 * 24 * 3600
    /// A cut shorter than this is not worth hearing; selection stops instead.
    static let minimumCutSeconds = 0.5
    static let outputSampleRate = 16_000.0
    static let outputBitRate = 32_000

    /// `~/Library/Application Support/Minutes/clips`.
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Minutes/clips", isDirectory: true)
    }

    static func isTimed(_ utterance: Utterance) -> Bool {
        utterance.start.isFinite && utterance.end.isFinite && utterance.start >= 0 && utterance.end > utterance.start
    }

    /// Which parts of the cluster's speech go into a clip, in time order.
    ///
    /// The cluster's utterances are ranked: those that no competing cluster's
    /// utterance overlaps come first, longest first (earlier wins a tie). Whole
    /// utterances are taken while they fit; the next one that does not fit is cut
    /// from its start to the remaining time, and selection stops. The budget
    /// counts the `gap` of silence between segments, so the finished clip is at
    /// most `maxSeconds` long.
    ///
    /// - Parameter competingClusterIDs: clusters whose speech is audible in the
    ///   same audio; nil means every other cluster.
    public static func plan(utterances: [Utterance], clusterID: String, competingClusterIDs: Set<String>? = nil,
                            maxSeconds: Double = defaultMaxSeconds, gap: Double = gapSeconds) -> [Segment] {
        let timed = utterances.filter(isTimed)
        let own = timed.filter { $0.clusterId == clusterID }
        let others = timed.filter { $0.clusterId != clusterID && (competingClusterIDs?.contains($0.clusterId) ?? true) }
        func overlapped(_ utterance: Utterance) -> Bool {
            others.contains { $0.start < utterance.end && $0.end > utterance.start }
        }
        let ranked = own.map { (utterance: $0, clean: !overlapped($0)) }.sorted { lhs, rhs in
            if lhs.clean != rhs.clean { return lhs.clean }
            let l = lhs.utterance.end - lhs.utterance.start, r = rhs.utterance.end - rhs.utterance.start
            if l != r { return l > r }
            return lhs.utterance.start < rhs.utterance.start
        }
        var chosen: [Segment] = []
        var used = 0.0
        for (utterance, _) in ranked {
            let remaining = maxSeconds - used - (chosen.isEmpty ? 0 : gap)
            let length = utterance.end - utterance.start
            if length <= remaining {
                chosen.append(Segment(start: utterance.start, end: utterance.end, text: utterance.text))
                used += length + (chosen.count > 1 ? gap : 0)
            } else {
                if remaining >= minimumCutSeconds {
                    chosen.append(Segment(start: utterance.start, end: utterance.start + remaining, text: utterance.text))
                }
                break
            }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Plans, encodes and stores a clip for `cluster`. Prunes old clips first.
    public static func make(meeting: Meeting, cluster: SpeakerCluster, clusters: [SpeakerCluster], utterances: [Utterance],
                            maxSeconds: Double = defaultMaxSeconds, directory: URL = defaultDirectory, now: Date = Date()) throws -> Output {
        try prepareDirectory(directory)
        prune(directory: directory, now: now)
        guard utterances.contains(where: { $0.clusterId == cluster.id && isTimed($0) }) else { throw SpeakerClipError.noTimedUtterances }
        let path: String
        do { path = try SpeakerAudioSample.audioPath(meeting: meeting, cluster: cluster) }
        catch { throw SpeakerClipError.audioUnavailable(error.localizedDescription) }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw SpeakerClipError.audioUnavailable("The meeting's audio file is missing.")
        }
        // A per-source capture file only carries that source's speakers.
        let perTrack = path != meeting.audioPath
        let competing = perTrack ? Set(clusters.filter { $0.trackId == cluster.trackId }.map(\.id)) : nil
        let segments = plan(utterances: utterances, clusterID: cluster.id, competingClusterIDs: competing, maxSeconds: maxSeconds)
        guard !segments.isEmpty else { throw SpeakerClipError.noTimedUtterances }

        let name = "\(safeName(meeting.id))-\(safeName(cluster.id))-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
        let final = directory.appendingPathComponent(name + ".m4a")
        let partial = directory.appendingPathComponent("." + name + ".partial.m4a")
        do {
            let duration = try write(segments: segments, from: URL(fileURLWithPath: path), to: partial)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            try FileManager.default.moveItem(at: partial, to: final)
            return Output(url: final, duration: duration, segments: segments)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if let error = error as? SpeakerClipError { throw error }
            throw SpeakerClipError.encodingFailed(error.localizedDescription)
        }
    }

    /// Creates `directory` (0700), and tightens it to 0700 if it already exists.
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Deletes files in `directory` last modified more than `retention` before `now`.
    @discardableResult
    public static func prune(directory: URL, now: Date = Date(), retention: TimeInterval = retention) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > retention else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(cleaned.prefix(48))
    }

    /// Writes `segments` of `source`, separated by `gap` seconds of silence, as
    /// mono AAC (16 kHz, ~32 kbps). Returns the written duration in seconds.
    public static func write(segments: [Segment], from source: URL, to destination: URL, gap: Double = gapSeconds) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let inputFormat = input.processingFormat
        let inputRate = inputFormat.sampleRate
        let sourceDuration = Double(input.length) / inputRate
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false) else {
            throw SpeakerClipError.encodingFailed("Unsupported output format.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: outputBitRate
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output.close() }
        var written: AVAudioFrameCount = 0

        for segment in segments {
            let start = max(0, segment.start), end = min(segment.end, sourceDuration)
            guard end > start else { continue }
            if written > 0 {
                let silenceFrames = AVAudioFrameCount((gap * outputSampleRate).rounded())
                guard let silence = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: silenceFrames) else { continue }
                silence.frameLength = silenceFrames
                if let channel = silence.floatChannelData?[0] { channel.update(repeating: 0, count: Int(silenceFrames)) }
                try output.write(from: silence)
                written += silenceFrames
            }
            input.framePosition = AVAudioFramePosition((start * inputRate).rounded(.down))
            let frames = AVAudioFrameCount(((end - start) * inputRate).rounded())
            for converted in try readConverted(input, frames: frames, to: mono) {
                try output.write(from: converted)
                written += converted.frameLength
            }
        }
        guard written > 0 else { throw SpeakerClipError.audioUnavailable("The clip's times are outside the recorded audio.") }
        return Double(written) / outputSampleRate
    }

    /// Reads `frames` from `input`'s current position (AVAudioFile may return
    /// fewer per read, so it reads until done or end of file) and converts them
    /// to `format` with one converter, drained so no frames are held back.
    private static func readConverted(_ input: AVAudioFile, frames: AVAudioFrameCount, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let inputFormat = input.processingFormat
        let chunkFrames: AVAudioFrameCount = 32_768
        nonisolated(unsafe) var remaining = frames
        nonisolated(unsafe) var readError: (any Error)?
        func nextChunk() -> AVAudioPCMBuffer? {
            guard remaining > 0, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: min(chunkFrames, remaining)) else { return nil }
            do { try input.read(into: buffer, frameCount: min(chunkFrames, remaining)) } catch { readError = error; return nil }
            guard buffer.frameLength > 0 else { return nil }
            remaining -= min(buffer.frameLength, remaining)
            return buffer
        }
        var chunks: [AVAudioPCMBuffer] = []
        if inputFormat == format {
            while let chunk = nextChunk() { chunks.append(chunk) }
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
                throw SpeakerClipError.encodingFailed("Cannot convert \(inputFormat) to mono.")
            }
            converter.downmix = true
            let capacity = AVAudioFrameCount((Double(chunkFrames) * format.sampleRate / inputFormat.sampleRate).rounded(.up)) + 1024
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw SpeakerClipError.encodingFailed("Out of memory.")
                }
                var conversionError: NSError?
                let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                    guard let chunk = nextChunk() else { inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return chunk
                }
                if status == .error { throw SpeakerClipError.encodingFailed(conversionError?.localizedDescription ?? "conversion failed") }
                if out.frameLength > 0 { chunks.append(out) }
                if status == .endOfStream || status == .inputRanDry { break }
            }
        }
        if let readError { throw readError }
        return chunks
    }
}
