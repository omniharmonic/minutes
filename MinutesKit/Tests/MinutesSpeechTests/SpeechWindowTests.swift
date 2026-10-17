import Foundation
import AVFoundation
import Testing
@testable import MinutesSpeech

private struct BoundedSpeechFixture: SpeechTranscriptionBackend {
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        let decoded = try AudioDecoder.decode(fileURL: audioURL)
        guard decoded.duration < 8 else { throw ASRError.transcriptionFailed("Fixture reproduces early finalization with long surrounding silence") }
        #expect(audioURL.pathExtension == "wav")
        return [ASRWord(word: "speech", start: 0.6, end: decoded.duration - 0.4, confidence: 1)]
    }
}
struct SpeechWindowTests {
    @Test func delayedSpeechUsesBoundedInputAndKeepsOriginalTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40 * 16000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
            for i in (12 * 16000)..<(18 * 16000) { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.04) }
            try file.write(from: buffer)
        }
        var embedding = [Float](repeating: 0, count: 256); embedding[0] = 1
        let pipeline = PipelineOrchestrator(asrService: BoundedSpeechFixture(), diarizationService: DiarizationService(backend: FixtureDiarizationBackend(output: [.init(speakerID: "one", start: 12, end: 18, embedding: embedding)])))
        let result = try await pipeline.process(meetingId: "delayed-speech", audioURL: url)
        #expect(result.words.count == 1)
        #expect(abs((result.words.first?.start ?? 0) - 12.2) < 0.001)
        #expect(result.utterances.count == 1)
        #expect(result.audioDuration == 40)
    }
}

private actor BoundarySpeechFixture: SpeechTranscriptionBackend {
    var call = 0
    var files: [URL] = []
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        files.append(audioURL)
        let current = call; call += 1
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        // The same boundary word appears in the context of both requests.
        let start = current == 0 ? 20.15 : 0.55
        return [ASRWord(word: "boundary", start: start, end: start + 0.2)]
    }
}
extension SpeechWindowTests {
    @Test func longSpeechHasBoundedOverlappingContext() {
        let windows = SpeechWindows.plan(segments: [.init(speakerId: "one", start: 0, end: 65)], duration: 65)
        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0.end - $0.start <= 20.8 + 0.0001 })
        #expect(windows[1].start < windows[0].end)
        #expect(windows[0].ownedEnd == windows[1].ownedStart)
    }
    @Test func separatedSpeechDoesNotSendLongSilenceToRecognizer() {
        let windows = SpeechWindows.plan(segments: [.init(speakerId: "one", start: 12, end: 16), .init(speakerId: "two", start: 90, end: 95)], duration: 120)
        #expect(windows.count == 2)
        #expect(windows[0].end < 17)
        #expect(windows[1].start > 89)
    }
    @Test func overlapWordsHaveOneOwnerAndTemporaryAudioIsRemoved() async throws {
        let backend = BoundarySpeechFixture()
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 40 * 16000), sampleRate: 16000, duration: 40)
        let planned = SpeechWindows.plan(segments: [.init(speakerId: "one", start: 0, end: 40)], duration: 40)
        let words = try await SpeechWindows.transcribePlannedWindows(audio: audio, windows: planned, backend: backend, fallbackTranscriptURL: nil)
        #expect(words.count == 1)
        #expect(abs((words.first?.start ?? 0) - 20.15) < 0.001)
        let files = await backend.files
        #expect(files.count == 2)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

private actor DistinctTurnSpeechFixture: SpeechTranscriptionBackend {
    var turn = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        let audio = try AudioDecoder.decode(fileURL: audioURL)
        let maximum = audio.samples.max() ?? 0, minimum = audio.samples.min() ?? 0
        let index = turn; turn += 1
        // Distinct real sample payloads establish that slicing did not skip or replace a turn.
        if index == 0 { #expect(maximum > 0.29 && minimum >= 0) }
        else { #expect(minimum < -0.19 && maximum <= 0) }
        return [ASRWord(word: index == 0 ? "first" : "second", start: 0.5, end: audio.duration - 0.4, confidence: 1)]
    }
}

extension SpeechWindowTests {
    @Test func bothSeparatedTurnsKeepTheirAudioAndOriginalOffsets() async throws {
        var samples = [Float](repeating: 0, count: 40 * 16000)
        for index in (8 * 16000)..<(20 * 16000) { samples[index] = 0.3 }
        for index in (24 * 16000)..<(36 * 16000) { samples[index] = -0.2 }
        let audio = DecodedAudio(samples: samples, sampleRate: 16000, duration: 40)
        let backend = DistinctTurnSpeechFixture()
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "first", start: 8, end: 20), .init(speakerId: "second", start: 24, end: 36)], backend: backend, fallbackTranscriptURL: nil)
        #expect(words.map(\.word) == ["first", "second"])
        #expect(words.count == 2)
        guard words.count == 2 else { return }
        #expect(abs(words[0].start - 8.1) < 0.001)
        #expect(abs(words[1].start - 24.1) < 0.001)
        let calls = await backend.turn
        #expect(calls == 2)
    }
}

private actor FirstTurnLossFixture: SpeechTranscriptionBackend {
    var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        let current = calls; calls += 1
        let audio = try AudioDecoder.decode(fileURL: audioURL)
        if current == 0 { return [] }
        if current == 1 { return [.init(word: "second", start: 0.5, end: audio.duration - 0.4)] }
        #expect(audio.duration <= 6.8 + 0.001)
        return [.init(word: "first", start: 0.6, end: 1.5)]
    }
}

private actor EmptySpeechFixture: SpeechTranscriptionBackend {
    var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] { calls += 1; return [] }
}

extension SpeechWindowTests {
    @Test func omittedFirstTurnIsRetriedInShortOwnedWindowsWithoutLosingSecondTurn() async throws {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 40 * 16000), sampleRate: 16000, duration: 40)
        let backend = FirstTurnLossFixture()
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "first", start: 8, end: 20), .init(speakerId: "second", start: 24, end: 36)], backend: backend, fallbackTranscriptURL: nil)
        #expect(words.contains { $0.word == "first" && $0.start >= 8 && $0.end <= 20 })
        #expect(words.filter { $0.word == "second" }.count == 1)
        #expect(abs((words.first { $0.word == "second" }?.start ?? 0) - 24.1) < 0.001)
        let calls = await backend.calls
        #expect(calls > 2 && calls <= 14)
    }

    @Test func substantialDetectedSpeechThatStillHasNoWordsFailsInsteadOfClaimingCompletion() async {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 8 * 16000), sampleRate: 16000, duration: 8)
        let backend = EmptySpeechFixture()
        await #expect(throws: ASRError.self) {
            try await SpeechWindows.transcribe(audio: audio, segments: [.init(speakerId: "first", start: 1, end: 7)], backend: backend, fallbackTranscriptURL: nil)
        }
        let calls = await backend.calls
        #expect(calls <= 13)
    }
}
