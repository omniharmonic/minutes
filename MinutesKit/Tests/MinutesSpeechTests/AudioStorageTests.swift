import AVFoundation
import Foundation
import Testing
@testable import MinutesSpeech

/// Quiet tone with one loud click, so timing can be measured after encoding.
private func writeTone(_ url: URL, seconds: Double, rate: Double = 48_000, clickAt: Double) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let click = Int(clickAt * rate)
    for i in 0..<Int(frames) {
        buffer.floatChannelData![0][i] = i >= click && i < click + Int(rate / 200) ? 0.9 : Float(0.05 * sin(Double(i) * 2 * .pi * 220 / rate))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func clickTime(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    let index = try #require(samples.firstIndex { abs($0) > 0.45 })
    return Double(index) / file.processingFormat.sampleRate
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-storage-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct AudioStorageTests {
    @Test("AAC compaction keeps length and timing within a few milliseconds")
    func timingSurvivesEncoding() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.caf"), encoded = root.appendingPathComponent("tone.m4a")
        try writeTone(source, seconds: 10, clickAt: 5)
        try AudioStorage.encode(source, to: encoded)
        #expect(abs(try clickTime(encoded) - 5) < 0.01)
        let file = try AVAudioFile(forReading: encoded)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 10) < 0.05)
        let sourceBytes = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let encodedBytes = try #require(try encoded.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(encodedBytes * 20 < sourceBytes)
    }

    @Test("A capture folder compacts to AAC, removes originals, and Regenerate still finds its sources")
    func captureFolderCompaction() async throws {
        let library = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: library) }
        let root = library.appendingPathComponent("audio/meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["system", "microphone", "aligned-system", "aligned-microphone", "mixed"] {
            try writeTone(root.appendingPathComponent(name + ".caf"), seconds: 4, clickAt: 2)
        }
        let track: (String) -> CaptureTrackTimeline = { source in
            CaptureTrackTimeline(source: CaptureAudioSource(rawValue: source)!, file: source + ".caf", sampleRate: 48_000, channels: 1,
                                 frameCount: 192_000, segments: [CaptureTimelineSegment(sourceFrame: 0, frameCount: 192_000, presentationTime: 0)])
        }
        let manifest = CaptureTimelineManifest(schema: "minutes.capture/1", clock: "SCStream.synchronizationClock", startedAt: Date(),
            completed: true, processingFile: "mixed.caf", timelineOrigin: 0, duration: 4, tracks: [track("microphone"), track("system")], issues: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("capture.json"))

        let before = AudioStorage.usage(audioPath: root.appendingPathComponent("mixed.caf").path)
        let path = try await AudioStorage.compact(audioPath: root.appendingPathComponent("mixed.caf").path,
                                                  managedDirectory: library.appendingPathComponent("audio"))
        #expect(path.hasSuffix("/mixed.m4a"))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(remaining == ["aligned-microphone.m4a", "aligned-system.m4a", "capture.json", "mixed.m4a"])
        let after = AudioStorage.usage(audioPath: path)
        #expect(after.isCompact && after.bytes * 10 < before.bytes)
        let sources = try #require(try CaptureSourceProcessing.sources(for: URL(fileURLWithPath: path)))
        #expect(sources.map(\.0) == ["system", "microphone"])
        #expect(sources.allSatisfy { $0.1.pathExtension == "m4a" })
    }

    @Test("Imported files outside the library are never compacted or deleted")
    func externalFilesUntouched() async throws {
        let library = try temporaryDirectory(), outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library); try? FileManager.default.removeItem(at: outside) }
        let mine = outside.appendingPathComponent("interview.wav")
        try writeTone(mine, seconds: 1, rate: 16_000, clickAt: 0.5)
        await #expect(throws: AudioStorage.StorageError.self) {
            try await AudioStorage.compact(audioPath: mine.path, managedDirectory: library)
        }
        #expect(throws: AudioStorage.StorageError.self) { try AudioStorage.deleteAudio(audioPath: mine.path, managedDirectory: library) }
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test("A single microphone recording compacts beside itself and deletes with its sidecar")
    func singleFileCompactionAndDeletion() async throws {
        let library = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: library) }
        let wav = library.appendingPathComponent("meeting_x.wav")
        try writeTone(wav, seconds: 3, rate: 16_000, clickAt: 1)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: wav.path + ".capture-diagnostics.json"))
        let path = try await AudioStorage.compact(audioPath: wav.path, managedDirectory: library)
        #expect(path.hasSuffix("meeting_x.m4a") && !FileManager.default.fileExists(atPath: wav.path))
        #expect(abs(try clickTime(URL(fileURLWithPath: path)) - 1) < 0.01)
        try AudioStorage.deleteAudio(audioPath: path, managedDirectory: library)
        #expect(AudioStorage.usage(audioPath: path).exists == false)
    }
}
