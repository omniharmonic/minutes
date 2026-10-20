import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import MinutesSpeech

@Suite("Synchronized capture archive without devices")
struct SynchronizedCaptureTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("capture-" + UUID().uuidString)
    }
    private func buffer(_ values: [Float], rate: Double = 48_000) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        for i in values.indices { buffer.floatChannelData![0][i] = values[i] }
        return buffer
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var values: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: output, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            guard output.frameLength > 0 else { throw NSError(domain: "CaptureTest.Read", code: 1) }
            values.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        return values
    }

    @Test("Source clock offsets become leading silence in the processing mix")
    func alignsOffsets() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer([1] + Array(repeating: 0, count: 479)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer([1] + Array(repeating: 0, count: 479)), source: .microphone,
                           presentationTime: CMTime(value: 1001, timescale: 10))
        let result = try archive.finish()
        let mixed = try samples(#require(result.processingURL))
        #expect(mixed.count == 5_280)
        #expect(abs(mixed[0] - 0.5) < 0.0001)
        #expect(abs(mixed[4_800] - 0.5) < 0.0001)
        #expect(mixed[2_000] == 0)
        #expect(try samples(result.systemAudioURL).count == 480)
        #expect(try samples(#require(result.microphoneURL)).count == 480)
    }

    @Test("Timestamp gaps preserve silence instead of shortening the captured timeline")
    func preservesGaps() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.25, count: 480)), source: .system,
                           presentationTime: CMTime(value: 20, timescale: 1))
        try archive.append(buffer(Array(repeating: 0.75, count: 480)), source: .system,
                           presentationTime: CMTime(value: 2002, timescale: 100))
        let result = try archive.finish()
        let mixed = try samples(#require(result.processingURL))
        #expect(mixed.count == 1_440)
        #expect(mixed[479] == 0.25)
        #expect(mixed[480] == 0)
        #expect(mixed[959] == 0)
        #expect(mixed[960] == 0.75)
    }

    @Test("A capture failure preserves source files and never returns a successful processing path")
    func retainsFailedCapture() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.2, count: 480)), source: .system,
                           presentationTime: CMTime(value: 10, timescale: 1))
        archive.recordFailure("Screen stream stopped unexpectedly")
        do { _ = try archive.finish(); Issue.record("Failed capture reported success") }
        catch let failure as CaptureFinalizationError {
            #expect(failure.result.processingURL == nil)
            #expect(FileManager.default.fileExists(atPath: failure.result.systemAudioURL.path))
            #expect(FileManager.default.fileExists(atPath: failure.result.manifestURL.path))
            #expect(failure.result.issues.contains("Screen stream stopped unexpectedly"))
        }
    }

    @Test("Different native sample rates render the same duration without changing pitch")
    func resamplesNativeAudio() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        let tone = (0..<44_100).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44_100)) * 0.4 }
        try archive.append(buffer(tone, rate: 44_100), source: .system, presentationTime: CMTime(value: 5, timescale: 1))
        let result = try archive.finish()
        let output = try samples(#require(result.processingURL))
        #expect(try AVAudioFile(forReading: #require(result.processingURL)).length == 48_000)
        #expect(output.count == 48_000)
        // Ignore the converter's boundary filter transient when measuring pitch.
        let crossings = (4_800..<43_200).filter { output[$0 - 1] <= 0 && output[$0] > 0 }.count
        #expect(abs(crossings - 352) <= 2)
        #expect(try AVAudioFile(forReading: result.systemAudioURL).length == 44_100)
    }

    @Test("Native stereo system audio downmixes both channels into the processing input")
    func stereoSystemAudio() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        pcm.frameLength = 4_800
        pcm.floatChannelData![0].update(repeating: 0.2, count: 4_800)
        pcm.floatChannelData![1].update(repeating: 0.6, count: 4_800)
        try archive.append(pcm, source: .system, presentationTime: CMTime(value: 1, timescale: 1))
        let result = try archive.finish()
        let output = try samples(#require(result.processingURL))
        #expect(output.count == 4_800)
        #expect(abs(output[2_400] - 0.4) < 0.001)
        #expect(try AVAudioFile(forReading: result.systemAudioURL).processingFormat.channelCount == 2)
    }

    @Test("A missing microphone still saves and mixes the Mac audio, and says so")
    func missingMicrophone() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer([0.2, 0.3]), source: .system, presentationTime: CMTime(value: 1, timescale: 1))
        let result = try archive.finish()
        #expect(result.processingURL != nil && result.issues.isEmpty)
        #expect(result.interruptions.contains { $0.contains("No microphone audio") })
        #expect(try samples(result.systemAudioURL).count == 2)
    }

    @Test("Nothing captured at all is the one case that cannot become a recording")
    func nothingCaptured() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        #expect(throws: CaptureFinalizationError.self) { try archive.finish() }
    }

    @Test("Backward source clocks preserve the captured prefix and fail finalization")
    func rejectsBackwardsClock() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.2, count: 480)), source: .system, presentationTime: CMTime(value: 10, timescale: 1))
        #expect(throws: (any Error).self) {
            try archive.append(buffer([0.8]), source: .system, presentationTime: CMTime(value: 9, timescale: 1))
        }
        #expect(throws: CaptureFinalizationError.self) { try archive.finish() }
        #expect(try samples(root.appendingPathComponent("system.caf")).count == 480)
    }

    @Test("A render failure retains the native source and marks the manifest incomplete")
    func renderFailure() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.2, count: 480)), source: .system, presentationTime: CMTime(value: 1, timescale: 1))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mixed.caf"), withIntermediateDirectories: false)
        do { _ = try archive.finish(); Issue.record("Broken render destination reported success") }
        catch let failure as CaptureFinalizationError {
            #expect(failure.result.processingURL == nil)
            #expect(try samples(failure.result.systemAudioURL).count == 480)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CaptureTimelineManifest.self, from: Data(contentsOf: failure.result.manifestURL))
            #expect(!manifest.completed)
            #expect(manifest.processingFile == nil)
        }
    }

    @Test("A replacement device with another sample rate is converted and the recording continues")
    func formatChange() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer(Array(repeating: 0.1, count: 48_000)), source: .system, presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0.2, count: 24_000), rate: 48_000), source: .microphone, presentationTime: CMTime(value: 100, timescale: 1))
        // The AirPods are gone; the built-in microphone delivers 44.1 kHz from the same moment.
        try archive.append(buffer(Array(repeating: 0.3, count: 22_050), rate: 44_100), source: .microphone, presentationTime: CMTime(value: 1005, timescale: 10))
        let result = try archive.finish()
        #expect(result.processingURL != nil)
        let microphone = try AVAudioFile(forReading: #require(result.microphoneURL))
        #expect(microphone.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(microphone.length) - 48_000) < 600)
    }

    @Test("A microphone that ends early is kept, mixed with Mac audio, and disclosed")
    func rejectsTruncatedMicrophone() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer(Array(repeating: 0.2, count: 48_000 * 12)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0.3, count: 24_000), rate: 24_000), source: .microphone,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try expectInterrupted(archive, root: root, issue: "Microphone audio stopped at", preservedMicFrames: 24_000)
    }

    @Test("A late microphone start is disclosed with its time")
    func rejectsLateMicrophone() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer(Array(repeating: 0.2, count: 48_000 * 4)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0.3, count: 48_000)), source: .microphone,
                           presentationTime: CMTime(value: 103, timescale: 1))
        try expectInterrupted(archive, root: root, issue: "Microphone audio started at 0:03", preservedMicFrames: 48_000)
    }

    @Test("A source dropout becomes silence and is listed with its times")
    func rejectsInternalDropout() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.2, count: 480)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0.3, count: 480)), source: .system,
                           presentationTime: CMTime(value: 101, timescale: 1))
        try expectInterrupted(archive, root: root, issue: "Mac audio is missing from 0:00 to 0:01")
    }

    @Test("Many individually short gaps are still disclosed in total")
    func rejectsAccumulatedDropouts() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        for index in 0..<8 {
            try archive.append(buffer(Array(repeating: 0.2, count: 480)), source: .system,
                               presentationTime: CMTime(value: Int64(10_000 + index * 21), timescale: 100))
        }
        try expectInterrupted(archive, root: root, issue: "brief dropouts")
    }

    @Test("Small startup and shutdown skew remain valid with silent microphone samples")
    func allowsBoundedDeviceSkew() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer(Array(repeating: 0.2, count: 48_000)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0, count: 24_000), rate: 24_000), source: .microphone,
                           presentationTime: CMTime(value: 1002, timescale: 10))
        let result = try archive.finish()
        #expect(result.issues.isEmpty)
        #expect(result.processingURL != nil)
    }

    @Test("A missing source is reported as stalled after a short startup grace")
    func liveStartupGrace() throws {
        for missing in [CaptureAudioSource.microphone, .system] {
            let root = location(); defer { try? FileManager.default.removeItem(at: root) }
            let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
            let peer: CaptureAudioSource = missing == .microphone ? .system : .microphone
            try archive.append(buffer(Array(repeating: 0, count: 48_000 * 3)), source: peer,
                               presentationTime: CMTime(value: 100, timescale: 1))
            #expect(archive.errorDescription == nil)
            try archive.append(buffer(Array(repeating: 0, count: 480)), source: peer,
                               presentationTime: CMTime(value: 103, timescale: 1))
            // A stall asks the capture service to restart that source; it is not a failure.
            #expect(archive.stalledSource() == missing)
            #expect(archive.errorDescription == nil)
            #expect(try archive.finish().processingURL != nil)
        }
    }

    @Test("A microphone dropout is detected as a stall, recovers when audio returns, and is disclosed")
    func liveMicrophoneDropout() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        try archive.append(buffer(Array(repeating: 0, count: 48_000)), source: .system,
                           presentationTime: CMTime(value: 100, timescale: 1))
        try archive.append(buffer(Array(repeating: 0, count: 24_000), rate: 24_000), source: .microphone,
                           presentationTime: CMTime(value: 100, timescale: 1))
        #expect(archive.stalledSource() == nil)
        try archive.append(buffer(Array(repeating: 0, count: 48_000 * 4)), source: .system,
                           presentationTime: CMTime(value: 101, timescale: 1))
        #expect(archive.stalledSource() == .microphone)
        #expect(archive.stalledSource(ignoringMicrophone: true) == nil)
        archive.recordInterruption("AirPods disconnected; now recording MacBook Pro Microphone.")
        // The replacement microphone delivers again from 104 s.
        try archive.append(buffer(Array(repeating: 0, count: 24_000), rate: 24_000), source: .microphone,
                           presentationTime: CMTime(value: 104, timescale: 1))
        #expect(archive.errorDescription == nil)
        let result = try archive.finish()
        #expect(result.processingURL != nil)
        #expect(result.interruptions.contains { $0.contains("AirPods disconnected") })
        #expect(result.interruptions.contains { $0.contains("Microphone audio is missing from 0:01 to 0:04") })
    }

    @Test("A requested stop still mixes everything captured")
    func requestedStop() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false)
        try archive.append(buffer(Array(repeating: 0.2, count: 4_800)), source: .system, presentationTime: CMTime(value: 1, timescale: 1))
        archive.requestStop("Recording stopped because audio capture could not be restarted after a device change.")
        #expect(archive.errorDescription?.contains("could not be restarted") == true)
        let result = try archive.finish()
        #expect(result.processingURL != nil)
        #expect(result.interruptions.contains { $0.contains("could not be restarted") })
    }

    @Test("Continuous silent callbacks keep requested sources healthy")
    func liveSilenceIsHealthy() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        for second in 0..<6 {
            try archive.append(buffer(Array(repeating: 0, count: 48_000)), source: .system,
                               presentationTime: CMTime(value: Int64(100 + second), timescale: 1))
            #expect(archive.errorDescription == nil)
            try archive.append(buffer(Array(repeating: 0, count: 24_000), rate: 24_000), source: .microphone,
                               presentationTime: CMTime(value: Int64(100 + second), timescale: 1))
            #expect(archive.errorDescription == nil)
        }
        #expect(try archive.finish().issues.isEmpty)
    }

    private func expectInterrupted(_ archive: SynchronizedCaptureArchive, root: URL,
                                   issue: String, preservedMicFrames: AVAudioFramePosition? = nil) throws {
        let result = try archive.finish()
        #expect(result.issues.isEmpty)
        #expect(result.interruptions.contains { $0.contains(issue) }, "\(result.interruptions)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("mixed.caf").path))
        if let preservedMicFrames {
            #expect(try AVAudioFile(forReading: #require(result.microphoneURL)).length == preservedMicFrames)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureTimelineManifest.self, from: Data(contentsOf: result.manifestURL))
        #expect(manifest.completed)
        #expect(manifest.interruptions?.contains { $0.contains(issue) } == true)
    }

    @Test("An existing recording directory is never overwritten")
    func refusesOverwrite() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("system.caf")
        try Data("original".utf8).write(to: original)
        #expect(throws: (any Error).self) { _ = try SynchronizedCaptureArchive(directory: root, includeMicrophone: false) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }
}

@Suite("System capture command validation without devices")
struct SystemCaptureOptionsTests {
    @Test func requiresExplicitBoundedDurationAndDirectory() {
        for arguments in [[], ["--seconds", "1"], ["--output-dir", "/tmp/unused", "--seconds", "nan"],
                          ["--output-dir", "/tmp/unused", "--seconds", "0"],
                          ["--output-dir", "/tmp/unused", "--seconds", "86401"],
                          ["--output-dir", "/tmp/unused", "--seconds", "1", "--unknown"],
                          ["--output-dir", "/tmp/unused", "--seconds", "1", "--seconds", "2"]] {
            #expect(throws: (any Error).self) { try SystemCaptureOptions(arguments: arguments) }
        }
    }
    @Test func permissionIsExplicitAndMicrophoneDefaultIsHonest() throws {
        let options = try SystemCaptureOptions(arguments: ["--output-dir", "/tmp/unused", "--seconds", "1"])
        #expect(options.includeMicrophone)
        #expect(!options.requestPermission)
        let systemOnly = try SystemCaptureOptions(arguments: ["--seconds", "2", "--output-dir", "/tmp/unused", "--system-only", "--request-permission"])
        #expect(!systemOnly.includeMicrophone)
        #expect(systemOnly.requestPermission)
    }
}
