import Foundation
import Testing
import AVFoundation
import MinutesCore
@testable import MinutesSpeech

/// Loud samples mark "laughter/noise" the recognizer answers with no speech.
/// The backend only sees a window file, so the marker travels in the audio itself.
private actor NoiseRegionFixture: SpeechTranscriptionBackend {
    private(set) var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        calls += 1
        let file = try AVAudioFile(forReading: audioURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        if samples.contains(where: { abs($0) > 0.4 }) { throw ASRError.noSpeechDetected }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return [.init(word: "fixture", start: 0, end: duration, confidence: 1)]
    }
}

private func audio(seconds: Int, noise: ClosedRange<Double>?) -> DecodedAudio {
    var samples = [Float](repeating: 0.1, count: 16_000 * seconds)
    if let noise {
        for i in Int(noise.lowerBound * 16_000)..<Int(noise.upperBound * 16_000) { samples[i] = 0.5 }
    }
    return DecodedAudio(samples: samples, sampleRate: 16_000, duration: Double(seconds))
}

struct TranscriptCoverageTests {
    @Test("A long meeting with a short unrecognizable burst is saved, with the gap reported")
    func shortNoiseBurstDoesNotDiscardMeeting() async throws {
        let transcription = try await SpeechWindows.transcribeWithCoverage(audio: audio(seconds: 60, noise: 30...36),
            segments: [.init(speakerId: "s", start: 0, end: 60)], backend: NoiseRegionFixture(), fallbackTranscriptURL: nil)
        #expect(!transcription.words.isEmpty)
        #expect(transcription.uncoveredSeconds >= 3)
        #expect(transcription.uncoveredSeconds < 15)
        #expect(abs(transcription.detectedSeconds - 60) < 0.001)
    }

    @Test("Mostly unrecognizable speech still fails honestly instead of claiming a transcript")
    func mostlyMissingSpeechFails() async {
        await #expect(throws: TranscriptCoverageError.self) {
            try await SpeechWindows.transcribeWithCoverage(audio: audio(seconds: 60, noise: 5...55),
                segments: [.init(speakerId: "s", start: 0, end: 60)], backend: NoiseRegionFixture(), fallbackTranscriptURL: nil)
        }
    }

    @Test("Coverage policy: no words never passes; small gaps pass; majority gaps fail")
    func policy() {
        #expect(!SpeechWindows.acceptsPartialTranscript(detectedSeconds: 100, uncoveredSeconds: 0, wordCount: 0))
        #expect(SpeechWindows.acceptsPartialTranscript(detectedSeconds: 2_000, uncoveredSeconds: 90, wordCount: 4_000))
        #expect(!SpeechWindows.acceptsPartialTranscript(detectedSeconds: 2_000, uncoveredSeconds: 1_500, wordCount: 30))
    }

    @Test("A skipped capture source and uncovered seconds both reach the merged result and its notice")
    func mergeCarriesCoverage() throws {
        let partial = PipelineResult(meetingId: "m", audioDuration: 60, sampleRate: 16_000, words: [], segments: [],
            clusters: [], utterances: [], speechDuration: 50, uncoveredSpeechSeconds: 7.4)
        let merged = CaptureSourceProcessing.merge(meetingID: "m", results: [("system", partial)], skippedSources: ["microphone"])
        #expect(merged.skippedSources == ["microphone"])
        #expect(abs(merged.uncoveredSpeechSeconds - 7.4) < 0.001)
        let notice = try #require(merged.coverageNotice)
        #expect(notice.contains("microphone track"))
        #expect(notice.contains("About 7 seconds"))
        let complete = PipelineResult(meetingId: "m", audioDuration: 1, sampleRate: 16_000, words: [], segments: [],
            clusters: [], utterances: [], speechDuration: 1)
        #expect(complete.coverageNotice == nil)
    }

    @Test("A recognition deadline that fires before the request is attached still resumes exactly once")
    func earlyDeadlineResumesOnce() async {
        let state = AtomicRecognitionState()
        state.resumeOnce(throwing: ASRError.recognitionTimedOut)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)
                // A late recognizer callback after the deadline must be ignored.
                state.resumeOnce(returning: [])
            }
            Issue.record("Expected the pending timeout")
        } catch ASRError.recognitionTimedOut {
        } catch { Issue.record("Unexpected \(error)") }
    }

    @Test("Timeouts are window-level misses; authorization failures are not")
    func timeoutIsRetryable() {
        #expect(ASRError.recognitionTimedOut.isWindowLevelMiss)
        #expect(ASRError.noSpeechDetected.isWindowLevelMiss)
        #expect(!ASRError.authorizationDenied.isWindowLevelMiss)
    }
}
