import Foundation
import MinutesCore

public struct PipelineResult: Sendable {
    public let meetingId: String
    public let audioDuration: Double
    public let sampleRate: Double
    public let words: [ASRWord]
    public let segments: [TimedSpeakerSegment]
    public let clusters: [SpeakerCluster]
    public let utterances: [Utterance]
    public let speechDuration: Double
    
    public init(
        meetingId: String,
        audioDuration: Double,
        sampleRate: Double,
        words: [ASRWord],
        segments: [TimedSpeakerSegment],
        clusters: [SpeakerCluster],
        utterances: [Utterance],
        speechDuration: Double
    ) {
        self.meetingId = meetingId
        self.audioDuration = audioDuration
        self.sampleRate = sampleRate
        self.words = words
        self.segments = segments
        self.clusters = clusters
        self.utterances = utterances
        self.speechDuration = speechDuration
    }
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
            for (source, url) in sources {
                try Task.checkCancellation()
                let prefix = source + "_"
                let names = Dictionary(uniqueKeysWithValues: speakerNames.compactMap { key, name -> (String, String)? in
                    key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), name) : nil
                })
                let result = try await process(meetingId: meetingId, audioURL: url,
                    fallbackTranscriptURL: fallbackTranscriptURL, speakerNames: names, config: config)
                results.append((source, result))
            }
            return CaptureSourceProcessing.merge(meetingID: meetingId, results: results)
        }
        guard fallbackTranscriptURL == nil else {
            throw ASRError.transcriptionFailed("Plain text has no verified audio timestamps. Import it as an untimed transcript instead.")
        }
        // 1. Decode audio into 16kHz mono float32 samples
        let decoded = try AudioDecoder.decode(fileURL: audioURL, targetSampleRate: 16000.0)
        
        // Model availability is checked before ASR so a missing setup never
        // prompts for speech permission and then fails after transcription.
        let diarizationResult = try await diarizationService.diarize(
            samples: decoded.samples, sampleRate: decoded.sampleRate,
            meetingId: meetingId, config: config
        )
        let words = try await SpeechWindows.transcribe(
            audio: decoded, segments: diarizationResult.segments,
            backend: asrService, fallbackTranscriptURL: fallbackTranscriptURL
        )

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
        
        // Recognition coverage is checked before merging, but confidence/noise
        // filtering must not turn a substantial detected voice into false success.
        let missingSubstantialVoice = diarizationResult.clusters.contains { cluster in
            cluster.speechSeconds >= 5 && !utterances.contains(where: { $0.clusterId == cluster.id })
        }
        guard !missingSubstantialVoice, !(diarizationResult.speechDuration >= 5 && utterances.isEmpty) else {
            throw ASRError.transcriptionFailed("Some detected speech did not produce usable transcript text. The complete audio is preserved. Try processing again; this attempt is incomplete.")
        }

        return PipelineResult(
            meetingId: meetingId,
            audioDuration: decoded.duration,
            sampleRate: decoded.sampleRate,
            words: words,
            segments: diarizationResult.segments,
            clusters: diarizationResult.clusters,
            utterances: utterances,
            speechDuration: diarizationResult.speechDuration
        )
    }
}
