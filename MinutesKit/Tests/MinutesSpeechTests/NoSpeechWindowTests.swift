import Foundation
import Testing
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
struct NoSpeechWindowTests {
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
            await #expect(throws: ASRError.self) {
                try await SpeechWindows.transcribe(audio: audio,
                    segments: [.init(speakerId: "speech", start: 1, end: 9)], backend: backend, fallbackTranscriptURL: nil)
            }
            let calls = await backend.calls
            #expect(noSpeech ? calls > 1 && calls <= 13 : calls == 1)
        }
    }
}
