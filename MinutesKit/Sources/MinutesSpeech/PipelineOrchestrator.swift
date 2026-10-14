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

public final class PipelineOrchestrator: Sendable {
    private let asrService: ASRService
    private let diarizationService: DiarizationService
    
    public init(
        asrService: ASRService = ASRService(),
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
        // 1. Decode audio into 16kHz mono float32 samples
        let decoded = try AudioDecoder.decode(fileURL: audioURL, targetSampleRate: 16000.0)
        
        // 2. Perform speech recognition
        let words = try await asrService.transcribe(
            audioURL: audioURL,
            fallbackTranscriptURL: fallbackTranscriptURL
        )
        
        // 3. Perform speaker diarization and acoustic clustering
        let diarizationResult = diarizationService.diarize(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            meetingId: meetingId,
            config: config
        )
        
        // 4. Merge words and diarization segments into speaker-attributed utterances
        let utterances = TranscriptMerger.merge(
            meetingId: meetingId,
            words: words,
            segments: diarizationResult.segments,
            speakerNames: speakerNames,
            config: config
        )
        
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
