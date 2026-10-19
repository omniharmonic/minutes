import Foundation
import AVFoundation
import os

struct SpeechRecognitionWindow: Sendable {
    let start: Double
    let end: Double
    let ownedStart: Double
    let ownedEnd: Double
}

/// Keep long silence and long sessions out of individual Speech requests. Each
/// padded window retains its source offset; overlapping context has one owner.
enum SpeechWindows {
    static func plan(segments: [TimedSpeakerSegment], duration: Double) -> [SpeechRecognitionWindow] {
        guard duration.isFinite, duration > 0 else { return [] }
        let context = 0.4
        let spans = segments.compactMap { segment -> (Double, Double)? in
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else { return nil }
            let start = max(0, segment.start - context), end = min(duration, segment.end + context)
            return start < end ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for span in spans {
            if let previous = merged.last, span.0 <= previous.1 + 0.8 {
                merged[merged.count - 1].1 = max(previous.1, span.1)
            } else { merged.append(span) }
        }
        var windows: [SpeechRecognitionWindow] = []
        for span in merged {
            var cursor = span.0
            while cursor < span.1 {
                let end = min(span.1, cursor + 20)
                windows.append(.init(start: max(span.0, cursor - context), end: min(span.1, end + context), ownedStart: cursor, ownedEnd: end))
                cursor = end
            }
        }
        return windows
    }

    struct Transcription: Sendable {
        let words: [ASRWord]
        let detectedSeconds: Double
        let uncoveredSeconds: Double
    }

    /// Decide whether a transcript that missed some detected sound is still worth
    /// saving. Diarization routinely marks laughter, typing, music and crosstalk
    /// as speech, and Apple's recognizer answers those with "no speech". Failing
    /// the whole meeting for that discarded real 30+ minute transcripts.
    static func acceptsPartialTranscript(detectedSeconds: Double, uncoveredSeconds: Double, wordCount: Int) -> Bool {
        guard wordCount > 0 else { return false }
        guard detectedSeconds > 0 else { return true }
        return uncoveredSeconds / detectedSeconds <= 0.5
    }

    static func transcribe(audio: DecodedAudio, segments: [TimedSpeakerSegment], backend: any SpeechTranscriptionBackend, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        try await transcribeWithCoverage(audio: audio, segments: segments, backend: backend, fallbackTranscriptURL: fallbackTranscriptURL).words
    }

    static func transcribeWithCoverage(audio: DecodedAudio, segments: [TimedSpeakerSegment], backend: any SpeechTranscriptionBackend, fallbackTranscriptURL: URL?) async throws -> Transcription {
        let windows = plan(segments: segments, duration: audio.duration)
        guard !windows.isEmpty else { return Transcription(words: [], detectedSeconds: 0, uncoveredSeconds: 0) }
        PipelineOrchestrator.logger.info("Recognizing \(windows.count, privacy: .public) speech windows")
        let primary = try await transcribePlannedWindows(audio: audio, windows: windows, backend: backend, fallbackTranscriptURL: fallbackTranscriptURL)
        let spans = detectedSpans(segments, duration: audio.duration)
        var result = primary
        var retryCount = 0
        // Budget per unresolved interval, never per recording. A long recording
        // must not spend every retry on its opening minute. Recompute gaps after
        // each pass so successful hypotheses are retained and not requested again.
        for length in [6.0, 3.0] {
            let gaps = unresolvedIntervals(spans: spans, words: result, minimumGap: 3)
            var retries: [SpeechRecognitionWindow] = []
            for gap in gaps {
                var cursor = gap.start
                while cursor < gap.end {
                    let end = min(gap.end, cursor + length)
                    retries.append(.init(start: max(0, cursor - 0.4), end: min(audio.duration, end + 0.4),
                        ownedStart: cursor, ownedEnd: end))
                    cursor = end
                }
            }
            retryCount += retries.count
            if !retries.isEmpty { PipelineOrchestrator.logger.info("Retrying \(retries.count, privacy: .public) shorter \(Int(length), privacy: .public)s windows") }
            let recovered = try await transcribePlannedWindows(audio: audio, windows: retries, backend: backend,
                fallbackTranscriptURL: fallbackTranscriptURL, phase: "retry-\(Int(length))")
            for word in recovered {
                let overlaps = result.contains { existing in
                    let overlap = min(existing.end, word.end) - max(existing.start, word.start)
                    return overlap > 0.5 * min(existing.end - existing.start, word.end - word.start)
                }
                if !overlaps { result.append(word) }
            }
        }
        let uncovered = unresolvedIntervals(spans: spans, words: result, minimumGap: 3)
        reportDiagnostics(["phase": "coverage", "primaryWords": primary.count, "retryWindows": retryCount,
            "addedWords": result.count - primary.count, "uncoveredSpans": uncovered.count])
        let detectedSeconds = spans.reduce(0) { $0 + ($1.end - $1.start) }
        let uncoveredSeconds = uncovered.reduce(0) { $0 + ($1.end - $1.start) }
        guard acceptsPartialTranscript(detectedSeconds: detectedSeconds, uncoveredSeconds: uncoveredSeconds, wordCount: result.count) else {
            throw TranscriptCoverageError("Most detected speech could not be transcribed after shorter retries. The complete audio is preserved. Try processing again; this attempt is incomplete.")
        }
        return Transcription(words: result.sorted { $0.start < $1.start },
            detectedSeconds: detectedSeconds, uncoveredSeconds: uncoveredSeconds)
    }

    private static func detectedSpans(_ segments: [TimedSpeakerSegment], duration: Double) -> [TimedSpeakerSegment] {
        var spans: [TimedSpeakerSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end.isFinite else { continue }
            let start = max(0, segment.start), end = min(duration, segment.end)
            guard end > start else { continue }
            if let previous = spans.last, previous.speakerId == segment.speakerId, start <= previous.end + 0.8 {
                spans[spans.count - 1] = .init(speakerId: previous.speakerId, start: previous.start, end: max(previous.end, end))
            } else { spans.append(.init(speakerId: segment.speakerId, start: start, end: end)) }
        }
        return spans
    }

    /// Find internal and trailing holes too: one word cannot certify a long
    /// diarization span as transcribed. Word timing includes natural pauses, so
    /// only sustained holes trigger recovery; this is not a word-accuracy score.
    static func unresolvedIntervals(spans: [TimedSpeakerSegment], words: [ASRWord], minimumGap: Double) -> [TimedSpeakerSegment] {
        let ordered = words.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var gaps: [TimedSpeakerSegment] = []
        for span in spans {
            var cursor = span.start
            for word in ordered where word.end > span.start && word.start < span.end {
                let start = max(span.start, word.start)
                if start - cursor >= minimumGap {
                    gaps.append(.init(speakerId: span.speakerId, start: cursor, end: start))
                }
                cursor = max(cursor, min(span.end, word.end))
            }
            if span.end - cursor >= minimumGap {
                gaps.append(.init(speakerId: span.speakerId, start: cursor, end: span.end))
            }
        }
        return gaps
    }

    /// Low-level extraction/ownership boundary, also exercised independently of retry policy.
    static func transcribePlannedWindows(audio: DecodedAudio, windows: [SpeechRecognitionWindow], backend: any SpeechTranscriptionBackend, fallbackTranscriptURL: URL?, phase: String = "primary") async throws -> [ASRWord] {
        guard !windows.isEmpty else { return [] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-speech-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var words: [ASRWord] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let startFrame = max(0, Int((window.start * audio.sampleRate).rounded(.down)))
            let endFrame = min(audio.samples.count, Int((window.end * audio.sampleRate).rounded(.up)))
            guard startFrame < endFrame else { continue }
            let offset = Double(startFrame) / audio.sampleRate
            let url = directory.appendingPathComponent("window-\(index).wav")
            try write(samples: audio.samples[startFrame..<endFrame], sampleRate: audio.sampleRate, to: url)
            let recognized: [ASRWord]
            do {
                recognized = try await backend.transcribe(audioURL: url, fallbackTranscriptURL: fallbackTranscriptURL)
            } catch let error as ASRError where error.isWindowLevelMiss {
                // One window can contain non-speech, be rejected by the local
                // recognizer or time out. Continue other windows and the bounded
                // short retry; the coverage policy still rejects mostly-missing speech.
                recognized = []
                reportDiagnostics(["phase": phase, "window": index, "start": window.start,
                    "end": window.end, "noSpeechResponse": 1])
            } catch {
                reportDiagnostics(["phase": phase, "window": index, "start": window.start,
                    "end": window.end, "recognitionFailed": 1])
                throw error
            }
            try Task.checkCancellation()
            let wordCountBefore = words.count
            for word in recognized {
                guard word.start.isFinite, word.end.isFinite, word.end > word.start else { continue }
                let start = max(offset, offset + word.start)
                let end = min(audio.duration, offset + word.end, Double(endFrame) / audio.sampleRate)
                let middle = (start + end) / 2
                guard end > start, middle >= window.ownedStart, middle < window.ownedEnd else { continue }
                words.append(ASRWord(word: word.word, start: start, end: end, confidence: word.confidence))
            }
            reportDiagnostics(["phase": phase, "window": index, "start": window.start, "end": window.end,
                "ownedStart": window.ownedStart, "ownedEnd": window.ownedEnd,
                "recognizedWords": recognized.count, "ownedWords": words.count - wordCountBefore,
                "minimumConfidence": recognized.map(\.confidence).min() ?? -1,
                "maximumConfidence": recognized.map(\.confidence).max() ?? -1,
                "firstWordStart": recognized.map(\.start).min() ?? -1,
                "lastWordEnd": recognized.map(\.end).max() ?? -1])
            try FileManager.default.removeItem(at: url)
        }
        return words.sorted { $0.start < $1.start }
    }

    /// Debug diagnostics contain numeric counts/timing only, never words or voice vectors.
    private static func reportDiagnostics(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        Logger(subsystem: "app.minutes", category: "SpeechWindows").debug("Speech window: \(text, privacy: .public)")
    }

    private static func write(samples: ArraySlice<Float>, sampleRate: Double, to url: URL) throws {
        guard samples.count <= Int(UInt32.max), samples.allSatisfy(\.isFinite),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = buffer.int16ChannelData?[0] else { throw SpeechModelsError.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        for (index, sample) in samples.enumerated() {
            output[index] = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
        }
        // Closing AVAudioFile before recognition is essential for a valid WAV header.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
    }
}
