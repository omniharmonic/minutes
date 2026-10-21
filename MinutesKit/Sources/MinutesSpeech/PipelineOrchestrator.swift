import Foundation
import MinutesCore
import os

public struct PipelineResult: Sendable {
    public let meetingId: String
    public let audioDuration: Double
    public let sampleRate: Double
    public let words: [ASRWord]
    public let segments: [TimedSpeakerSegment]
    public let clusters: [SpeakerCluster]
    public let utterances: [Utterance]
    public let speechDuration: Double
    /// Seconds of detected sound that produced no recognized words after all
    /// retries. Non-zero means the transcript is saved but incomplete.
    public let uncoveredSpeechSeconds: Double
    /// Capture sources ("microphone", "system") left out for producing too little text.
    public let skippedSources: [String]

    public init(
        meetingId: String,
        audioDuration: Double,
        sampleRate: Double,
        words: [ASRWord],
        segments: [TimedSpeakerSegment],
        clusters: [SpeakerCluster],
        utterances: [Utterance],
        speechDuration: Double,
        uncoveredSpeechSeconds: Double = 0,
        skippedSources: [String] = []
    ) {
        self.meetingId = meetingId
        self.audioDuration = audioDuration
        self.sampleRate = sampleRate
        self.words = words
        self.segments = segments
        self.clusters = clusters
        self.utterances = utterances
        self.speechDuration = speechDuration
        self.uncoveredSpeechSeconds = uncoveredSpeechSeconds
        self.skippedSources = skippedSources
    }

    /// User-facing note for a saved transcript that missed some detected sound.
    public var coverageNotice: String? {
        var notes: [String] = []
        if !skippedSources.isEmpty {
            let names = skippedSources.map { $0 == "system" ? "call audio" : $0 }.joined(separator: " and ")
            notes.append("The \(names) track produced almost no words and was left out.")
        }
        if uncoveredSpeechSeconds >= 1 {
            notes.append("About \(Int(uncoveredSpeechSeconds.rounded())) seconds of detected sound produced no words (often laughter, noise or crosstalk).")
        }
        guard !notes.isEmpty else { return nil }
        return (notes + ["Audio is preserved."]).joined(separator: " ")
    }
}

/// Too little of the detected speech was recognized to call the transcript usable.
/// Distinct from hard recognizer failures so one weak capture source cannot
/// discard another source's complete transcript.
public struct TranscriptCoverageError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Allows deterministic plumbing tests without fabricated production transcripts.
public protocol SpeechTranscriptionBackend: Sendable {
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord]
}

extension ASRService: SpeechTranscriptionBackend {}

public final class PipelineOrchestrator: Sendable {
    private let asrService: any SpeechTranscriptionBackend
    private let diarizationService: DiarizationService
    
    public init(
        asrService: any SpeechTranscriptionBackend = ASRService(),
        diarizationService: DiarizationService = DiarizationService()
    ) {
        self.asrService = asrService
        self.diarizationService = diarizationService
    }
    
    /// Executes the full speech processing pipeline: audio decode -> ASR -> VAD & Diarization -> Utterance Alignment.
    public func process(
        meetingId: String,
        audioURL: URL,
        fallbackTranscriptURL: URL? = nil,
        speakerNames: [String: String] = [:],
        config: DiarizationConfig = DiarizationConfig()
    ) async throws -> PipelineResult {
        if let sources = try CaptureSourceProcessing.sources(for: audioURL) {
            guard speakerNames.keys.allSatisfy({ $0.hasPrefix("system_") || $0.hasPrefix("microphone_") }) else {
                throw ASRError.transcriptionFailed("Separate capture sources require source-qualified speaker IDs; no identity was assigned.")
            }
            var results: [(String, PipelineResult)] = []
            var weakSources: [(String, TranscriptCoverageError)] = []
            for (source, url) in sources {
                try Task.checkCancellation()
                let prefix = source + "_"
                let names = Dictionary(uniqueKeysWithValues: speakerNames.compactMap { key, name -> (String, String)? in
                    key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), name) : nil
                })
                let share = Double(results.count + weakSources.count) / Double(sources.count)
                do {
                    let result = try await ProcessingProgress.within(share...(share + 1 / Double(sources.count))) {
                        try await process(meetingId: meetingId, audioURL: url,
                            fallbackTranscriptURL: fallbackTranscriptURL, speakerNames: names, config: config)
                    }
                    results.append((source, result))
                } catch let error as TranscriptCoverageError {
                    // A muted microphone picking up room noise must not discard
                    // the call audio transcript, and vice versa.
                    Self.logger.info("Source \(source, privacy: .public) produced too little text; continuing with other sources")
                    weakSources.append((source, error))
                }
            }
            guard !results.isEmpty else { throw weakSources.first?.1 ?? TranscriptCoverageError("No capture source produced usable transcript text. The complete audio is preserved.") }
            return CaptureSourceProcessing.merge(meetingID: meetingId, results: results, skippedSources: weakSources.map(\.0))
        }
        guard fallbackTranscriptURL == nil else {
            throw ASRError.transcriptionFailed("Plain text has no verified audio timestamps. Import it as an untimed transcript instead.")
        }
        // 1. Decode audio into 16kHz mono float32 samples
        ProcessingProgress.report(0, phase: "Reading audio")
        let decoded = try AudioDecoder.decode(fileURL: audioURL, targetSampleRate: 16000.0)
        ProcessingProgress.report(0.03, phase: "Finding speakers")
        
        // Model availability is checked before ASR so a missing setup never
        // prompts for speech permission and then fails after transcription.
        let diarizationResult = try await ProcessingProgress.within(0.03...0.2) {
            // Speaker models run about 60x faster than real time on device.
            try await ProcessingProgress.estimating(expectedSeconds: decoded.duration / 60, phase: "Finding speakers") {
                try await diarizationService.diarize(samples: decoded.samples, sampleRate: decoded.sampleRate,
                    meetingId: meetingId, config: config)
            }
        }
        Self.logger.info("Diarized \(decoded.duration, privacy: .public)s audio: \(diarizationResult.segments.count, privacy: .public) segments, \(diarizationResult.speechDuration, privacy: .public)s speech")
        let transcription = try await ProcessingProgress.within(0.2...0.98) {
            try await SpeechWindows.transcribeWithCoverage(
                audio: decoded, segments: diarizationResult.segments,
                backend: asrService, fallbackTranscriptURL: fallbackTranscriptURL
            )
        }
        let words = transcription.words

        // 4. Merge words and diarization segments into speaker-attributed utterances
        // Acoustic cluster IDs are storage keys; give every cluster its display label.
        // Explicit caller-provided names remain authoritative.
        var displayNames: [String: String] = [:]
        for cluster in diarizationResult.clusters { displayNames[cluster.id] = cluster.label }
        displayNames.merge(speakerNames) { _, explicit in explicit }
        let utterances = TranscriptMerger.merge(
            meetingId: meetingId,
            words: words,
            segments: diarizationResult.segments,
            speakerNames: displayNames,
            config: config
        )
        
        // Substantial detected speech with no text at all is never a success.
        // Partial coverage is saved and reported instead of discarding the meeting.
        guard !(diarizationResult.speechDuration >= 5 && utterances.isEmpty) else {
            throw TranscriptCoverageError("Detected speech did not produce usable transcript text. The complete audio is preserved. Try processing again.")
        }
        // A "voice" cluster with no text is usually noise or echo diarized as speech.
        let silentClusterSeconds = diarizationResult.clusters
            .filter { cluster in !utterances.contains(where: { $0.clusterId == cluster.id }) }
            .reduce(0) { $0 + $1.speechSeconds }
        Self.logger.info("Transcribed \(words.count, privacy: .public) words, \(utterances.count, privacy: .public) utterances; uncovered \(transcription.uncoveredSeconds, privacy: .public)s, textless clusters \(silentClusterSeconds, privacy: .public)s")

        return PipelineResult(
            meetingId: meetingId,
            audioDuration: decoded.duration,
            sampleRate: decoded.sampleRate,
            words: words,
            segments: diarizationResult.segments,
            clusters: diarizationResult.clusters,
            utterances: utterances,
            speechDuration: diarizationResult.speechDuration,
            uncoveredSpeechSeconds: transcription.uncoveredSeconds
        )
    }

    static let logger = Logger(subsystem: "app.minutes", category: "Pipeline")
}
