import AVFoundation
import Foundation
import MinutesCore
import os

/// Recording storage after transcription. Captures are written as 48 kHz
/// Float32 originals plus aligned copies (~2.1 GB for 37 minutes). Compaction
/// keeps only what playback and Regenerate read, as mono AAC (~40 MB), and
/// removes originals only after every encoded file decodes to the same length.
public enum AudioStorage {
    static let logger = Logger(subsystem: "app.minutes", category: "AudioStorage")

    public struct Usage: Sendable, Equatable {
        public let bytes: Int64
        public let isCompact: Bool
        public let exists: Bool
    }

    public enum StorageError: Error, LocalizedError {
        case missingAudio, verificationFailed(String), unsupportedLayout, notManaged
        public var errorDescription: String? {
            switch self {
            case .missingAudio: "This meeting's audio file is missing."
            case .verificationFailed(let file): "The compressed copy of \(file) did not match the original, so the original was kept."
            case .unsupportedLayout: "This recording's files are not in a layout Minutes can compress. The original was kept."
            case .notManaged: "This audio lives outside the Minutes library, so Minutes will not change or delete it."
            }
        }
    }

    /// Only files Minutes recorded or copied into its own library may be
    /// rewritten or deleted; an imported file's original is never touched.
    public static func isManaged(audioPath: String, managedDirectory: URL) -> Bool {
        let root = managedDirectory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() + "/"
        let path = URL(fileURLWithPath: audioPath).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return path.hasPrefix(root)
    }

    /// A capture folder (`<id>/mixed.*` with `capture.json`) or a single file.
    static func captureDirectory(for audioPath: String) -> URL? {
        let url = URL(fileURLWithPath: audioPath)
        guard url.deletingPathExtension().lastPathComponent == "mixed" else { return nil }
        let root = url.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("capture.json").path) ? root : nil
    }

    /// Files belonging to a meeting's audio, including diagnostics sidecars.
    static func files(for audioPath: String) -> [URL] {
        let url = URL(fileURLWithPath: audioPath)
        if let root = captureDirectory(for: audioPath) {
            return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        }
        let siblings = [url, URL(fileURLWithPath: audioPath + ".capture-diagnostics.json")]
        return siblings.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func usage(audioPath: String?) -> Usage {
        guard let audioPath, FileManager.default.fileExists(atPath: audioPath) else { return Usage(bytes: 0, isCompact: false, exists: false) }
        let bytes = files(for: audioPath).reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Usage(bytes: bytes, isCompact: URL(fileURLWithPath: audioPath).pathExtension.lowercased() == "m4a", exists: true)
    }

    /// Returns the meeting's new audio path. Already-compact audio is unchanged.
    public static func compact(audioPath: String, managedDirectory: URL) async throws -> String {
        guard isManaged(audioPath: audioPath, managedDirectory: managedDirectory) else { throw StorageError.notManaged }
        return try await Task.detached(priority: .utility) { try compactSynchronously(audioPath: audioPath) }.value
    }

    static func compactSynchronously(audioPath: String) throws -> String {
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else { throw StorageError.missingAudio }
        if url.pathExtension.lowercased() == "m4a" { return audioPath }
        guard let root = captureDirectory(for: audioPath) else {
            let destination = url.deletingPathExtension().appendingPathExtension("m4a")
            try encode(url, to: destination)
            try FileManager.default.removeItem(at: url)
            logger.info("Compacted single recording")
            return destination.path
        }
        let manifestURL = root.appendingPathComponent("capture.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureTimelineManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.processingFile == url.lastPathComponent else { throw StorageError.unsupportedLayout }
        // Encode everything first; delete nothing until all copies verify.
        let names = ["mixed"] + manifest.tracks.map { "aligned-\($0.source.rawValue)" }
        var encoded: [URL] = []
        do {
            for name in names {
                let source = root.appendingPathComponent(name + ".caf")
                guard FileManager.default.fileExists(atPath: source.path) else { throw StorageError.unsupportedLayout }
                let destination = root.appendingPathComponent(name + ".m4a")
                try encode(source, to: destination)
                encoded.append(destination)
            }
        } catch {
            for file in encoded { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        let updated = CaptureTimelineManifest(schema: manifest.schema, clock: manifest.clock, startedAt: manifest.startedAt,
            completed: manifest.completed, processingFile: "mixed.m4a", timelineOrigin: manifest.timelineOrigin,
            duration: manifest.duration, tracks: manifest.tracks, issues: manifest.issues)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: manifestURL, options: .atomic)
        for name in names { try? FileManager.default.removeItem(at: root.appendingPathComponent(name + ".caf")) }
        // Raw captures are not read by playback or Regenerate once aligned copies exist.
        for track in manifest.tracks { try? FileManager.default.removeItem(at: root.appendingPathComponent(track.file)) }
        logger.info("Compacted capture with \(manifest.tracks.count, privacy: .public) sources")
        return root.appendingPathComponent("mixed.m4a").path
    }

    /// Deletes a meeting's audio files. Transcript, speakers and notes are untouched.
    public static func deleteAudio(audioPath: String, managedDirectory: URL) throws {
        guard isManaged(audioPath: audioPath, managedDirectory: managedDirectory) else { throw StorageError.notManaged }
        if let root = captureDirectory(for: audioPath) {
            try FileManager.default.removeItem(at: root)
        } else {
            for file in files(for: audioPath) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Never touch audio a capture, processing run or interrupted-recording
    /// recovery (which expects the original WAV) may still be reading.
    public static func isCompactable(_ meeting: Meeting) -> Bool {
        !["starting", "recording", "finalized", "processing", "transcribing", "summarizing", "interrupted"].contains(meeting.status)
            && meeting.audioPath != nil && meeting.platform != "transcript_import"
    }

    /// Recently Deleted meetings keep their audio until it is removed here.
    static func anyMeeting(id: String, store: MinutesStore) -> Meeting? {
        store.getMeeting(id: id) ?? store.listMeetings(inTrash: true).first { $0.id == id }
    }

    /// Compacts and records the new path. Returns bytes freed.
    @discardableResult
    public static func compactMeeting(id: String, store: MinutesStore, managedDirectory: URL) async throws -> Int64 {
        guard let meeting = anyMeeting(id: id, store: store), let path = meeting.audioPath else { throw StorageError.missingAudio }
        let before = usage(audioPath: path).bytes
        let compacted = try await compact(audioPath: path, managedDirectory: managedDirectory)
        // Re-read: the user may have edited the meeting while encoding ran.
        guard var latest = anyMeeting(id: id, store: store), latest.audioPath == path else { return 0 }
        latest.audioPath = compacted
        try store.saveMeeting(latest)
        return before - usage(audioPath: compacted).bytes
    }

    /// Deletes the audio and clears the path; Regenerate is no longer possible.
    @discardableResult
    public static func deleteMeetingAudio(id: String, store: MinutesStore, managedDirectory: URL) throws -> Int64 {
        guard let meeting = anyMeeting(id: id, store: store), let path = meeting.audioPath else { return 0 }
        let bytes = usage(audioPath: path).bytes
        if FileManager.default.fileExists(atPath: path) { try deleteAudio(audioPath: path, managedDirectory: managedDirectory) }
        try store.clearAudioPath(meetingId: id)
        return bytes
    }

    /// Mono AAC: 24 kHz (16 kHz sources stay 16 kHz) keeps speech clear for
    /// playback and is above the 16 kHz that recognition and diarization use.
    /// Joins recordings end to end as one mono AAC file (Continue Recording) and
    /// returns where each source starts in the result, in seconds.
    public static func join(_ sources: [URL], to destination: URL) throws -> [Double] {
        guard !sources.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw StorageError.verificationFailed(destination.lastPathComponent) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".joining-" + destination.lastPathComponent)
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var offsets: [Double] = []
        var expected = 0.0
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            for source in sources {
                // Source durations, not the encoder's buffered length, mark where each part starts.
                offsets.append(expected)
                let input = try AVAudioFile(forReading: source)
                expected += Double(input.length) / input.processingFormat.sampleRate
                guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
                      let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192) else {
                    throw StorageError.verificationFailed(source.lastPathComponent)
                }
                converter.downmix = true
                while true {
                    var conversionError: NSError?
                    var readError: Error?
                    let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
                        do {
                            if input.framePosition >= input.length { inputStatus.pointee = .endOfStream; return nil }
                            try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(Int64(8_192), Int64(requested), input.length - input.framePosition)))
                            inputStatus.pointee = .haveData
                            return inputBuffer
                        } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
                    }
                    if let readError { throw readError }
                    if status == .error { throw conversionError ?? StorageError.verificationFailed(source.lastPathComponent) }
                    if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
                    if status == .endOfStream { break }
                }
            }
        }
        let check = try AVAudioFile(forReading: temporary)
        guard abs(Double(check.length) / check.processingFormat.sampleRate - expected) <= max(0.5, expected * 0.002) else {
            throw StorageError.verificationFailed(destination.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return offsets
    }

    static func encode(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let rate = min(24_000, input.processingFormat.sampleRate)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".encoding-" + destination.lastPathComponent)
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw StorageError.verificationFailed(source.lastPathComponent)
        }
        converter.downmix = true
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: rate >= 24_000 ? 48_000 : 32_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            while true {
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
                    do {
                        if input.framePosition >= input.length { inputStatus.pointee = .endOfStream; return nil }
                        try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(Int64(8_192), Int64(requested), input.length - input.framePosition)))
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }
                if status == .error { throw conversionError ?? StorageError.verificationFailed(source.lastPathComponent) }
                if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
                if status == .endOfStream { break }
            }
        }
        let sourceSeconds = Double(input.length) / input.processingFormat.sampleRate
        let check = try AVAudioFile(forReading: temporary)
        let encodedSeconds = Double(check.length) / check.processingFormat.sampleRate
        guard abs(encodedSeconds - sourceSeconds) <= max(0.25, sourceSeconds * 0.001) else {
            throw StorageError.verificationFailed(source.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
