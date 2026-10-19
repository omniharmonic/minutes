import Foundation
import Testing
import AVFoundation
@testable import MinutesSpeech

private actor NoSpeechThenWords: SpeechTranscriptionBackend {
    private(set) var files: [URL] = []
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        files.append(audioURL)
        if files.count == 1 { throw ASRError.noSpeechDetected }
        return [.init(word: "generated", start: 0.6, end: 5.6, confidence: 1)]
    }
}
private actor RecognitionFailureFixture: SpeechTranscriptionBackend {
    let noSpeech: Bool
    private(set) var calls = 0
    init(noSpeech: Bool) { self.noSpeech = noSpeech }
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        calls += 1
        if noSpeech { throw ASRError.noSpeechDetected }
        throw ASRError.authorizationDenied
    }
}
private actor LongRecoveryFixture: SpeechTranscriptionBackend {
    private(set) var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        calls += 1
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if duration > 8 { throw ASRError.noSpeechDetected }
        return [.init(word: "fixture", start: 0, end: duration, confidence: 1)]
    }
}
private actor RetryOverlapFixture: SpeechTranscriptionBackend {
    var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        calls += 1
        if calls == 1 {
            return [.init(word: "opening", start: 0, end: 8, confidence: 1),
                    .init(word: "ending", start: 14, end: 20, confidence: 1)]
        }
        return [.init(word: "opening", start: 0, end: 0.3, confidence: 1),
                .init(word: "middle", start: 0.4, end: 6.4, confidence: 1),
                .init(word: "ending", start: 6.5, end: 6.8, confidence: 1)]
    }
}
struct NoSpeechWindowTests {
    @Test("Speaker attribution preserves zero-confidence recognized words")
    func lowConfidenceWordsAreNotDeleted() {
        let words = [ASRWord(word: "keep", start: 0, end: 1, confidence: 0),
                     ASRWord(word: "both", start: 1, end: 2, confidence: 0.9)]
        let utterances = TranscriptMerger.merge(meetingId: "test", words: words,
            segments: [.init(speakerId: "s", start: 0, end: 2)], config: .init(aggressiveness: 1))
        #expect(utterances.flatMap(\.words).map(\.word) == ["keep", "both"])
        #expect(utterances.first?.words.first?.confidence == 0)
    }
    @Test("Retry context cannot duplicate already recognized words on either side of a gap")
    func retryOverlapHasOneOwner() async throws {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 16000 * 20), sampleRate: 16000, duration: 20)
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "s", start: 0, end: 20)], backend: RetryOverlapFixture(), fallbackTranscriptURL: nil)
        #expect(words.map(\.word) == ["opening", "middle", "ending"])
        #expect(abs(words[1].start - 8) < 0.001)
        #expect(abs(words[1].end - 14) < 0.001)
    }
    @Test("Every part of a long recording receives shorter retries, including the final minute")
    func fullLengthRecovery() async throws {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 16000 * 401), sampleRate: 16000, duration: 401)
        let backend = LongRecoveryFixture()
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "speaker", start: 0, end: 401)], backend: backend, fallbackTranscriptURL: nil)
        #expect((words.last?.end ?? 0) >= 400)
        #expect(SpeechWindows.unresolvedIntervals(spans: [.init(speakerId: "speaker", start: 0, end: 401)], words: words, minimumGap: 0.01).isEmpty)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(await backend.calls > 60)
    }
    @Test("Recognized words at the beginning do not hide missing middle and trailing speech")
    func internalGaps() {
        let gaps = SpeechWindows.unresolvedIntervals(spans: [.init(speakerId: "s", start: 0, end: 30)],
            words: [.init(word: "a", start: 0, end: 2, confidence: 1), .init(word: "b", start: 12, end: 14, confidence: 1)], minimumGap: 5)
        #expect(gaps.count == 2)
        #expect(gaps.first?.start == 2)
        #expect(gaps.last?.end == 30)
    }
    @Test("Only the exact observed Assistant no-speech error becomes a typed empty-window response")
    func classifyExactErrorOnly() {
        let error = ASRService.classifyRecognitionError(NSError(domain: "kAFAssistantErrorDomain", code: 1110))
        if case .noSpeechDetected = error {} else { Issue.record("Expected typed no-speech response") }
        // Same code in another domain, authorization, interruption, timeout and
        // arbitrary failures must never be mistaken for an empty speech window.
        for (domain, code) in [("OtherDomain", 1110), ("kAFAssistantErrorDomain", 1101),
            ("kAFAssistantErrorDomain", 1700), (NSURLErrorDomain, -1001), (NSCocoaErrorDomain, 3072)] {
            if case .noSpeechDetected = ASRService.classifyRecognitionError(NSError(domain: domain, code: code)) {
                Issue.record("Unrelated recognition failure was swallowed")
            }
        }
    }
    @Test("An empty intro window does not discard later recognized speech or leak temporary audio")
    func laterWindowStillRecognized() async throws {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 16_000 * 16), sampleRate: 16_000, duration: 16)
        let backend = NoSpeechThenWords()
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "intro", start: 1, end: 2), .init(speakerId: "speech", start: 8, end: 14)],
            backend: backend, fallbackTranscriptURL: nil)
        #expect(words.count == 1)
        #expect(abs((words.first?.start ?? 0) - 8.2) < 0.001)
        let files = await backend.files
        #expect(files.count == 2)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    @Test("A no-speech primary request reaches bounded shorter recovery")
    func shorterRecoveryStillRuns() async throws {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 16_000 * 10), sampleRate: 16_000, duration: 10)
        let backend = NoSpeechThenWords()
        let words = try await SpeechWindows.transcribe(audio: audio,
            segments: [.init(speakerId: "speech", start: 1, end: 9)], backend: backend, fallbackTranscriptURL: nil)
        #expect(!words.isEmpty)
        #expect(await backend.files.count > 1)
    }
    @Test("All no-speech windows remain incomplete for substantial detected speech; other errors abort immediately")
    func failuresStayHonest() async {
        let audio = DecodedAudio(samples: [Float](repeating: 0.1, count: 16_000 * 10), sampleRate: 16_000, duration: 10)
        for noSpeech in [false, true] {
            let backend = RecognitionFailureFixture(noSpeech: noSpeech)
            await #expect(throws: (any Error).self) {
                try await SpeechWindows.transcribe(audio: audio,
                    segments: [.init(speakerId: "speech", start: 1, end: 9)], backend: backend, fallbackTranscriptURL: nil)
            }
            // No words at all is a coverage failure; a hard recognizer error stays an ASRError.
            do {
                _ = try await SpeechWindows.transcribe(audio: audio,
                    segments: [.init(speakerId: "speech", start: 1, end: 9)], backend: RecognitionFailureFixture(noSpeech: noSpeech), fallbackTranscriptURL: nil)
            } catch {
                #expect(noSpeech ? error is TranscriptCoverageError : error is ASRError)
            }
            let calls = await backend.calls
            #expect(noSpeech ? calls > 1 && calls <= 13 : calls == 1)
        }
    }
}
