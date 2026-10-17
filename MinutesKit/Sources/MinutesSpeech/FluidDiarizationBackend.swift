import Foundation
import FluidAudio
import CoreML

public enum SpeechModelsError: Error, LocalizedError, Sendable {
    case missingDiarizationModels
    case invalidAudio
    case invalidDiarizationOutput

    public var errorDescription: String? {
        switch self {
        case .missingDiarizationModels:
            "Speaker models are not installed. Use Settings → Set up speaker models or minutes-cli models setup before processing."
        case .invalidAudio:
            "Speaker diarization requires finite, mono 16 kHz audio."
        case .invalidDiarizationOutput:
            "The speaker model returned invalid timing or embeddings; no speaker identities were saved."
        }
    }
}

/// Values crossing the SDK boundary; quality scores are not identity confidence.
public struct TrainedSpeakerSegment: Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]

    public init(speakerID: String, start: Double, end: Double, embedding: [Float]) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

public protocol SpeakerDiarizationBackend: Sendable {
    func diarize(samples: [Float], config: DiarizationConfig) async throws -> [TrainedSpeakerSegment]
}

/// Automatic diarization uses cosine DISTANCE (0 is identical, 2 opposite),
/// independent of the similarity thresholds used to identify remembered people.
/// FluidAudio 0.17.7's manager multiplies its clustering setting by 1.2; the
/// default therefore accepts distance 0.84, much looser than SpeakerManager's
/// documented standalone 0.65 default. Keep that conservative assignment bound
/// explicitly, without setting an expected speaker count. Brief noisy fragments
/// can remain separate and must be reviewed rather than forcibly merged.
struct AutomaticSpeakerClusteringPolicy: Sendable {
    let maximumAssignmentCosineDistance: Float
    static let conservative = Self(maximumAssignmentCosineDistance: 0.65)
}

/// Owns SDK state on one executor. No downloader or auto-recovery API is used
/// here: corrupt or absent bundles fail without any network access.
public actor FluidDiarizationBackend: SpeakerDiarizationBackend {
    private let models: ModelManager

    public init(models: ModelManager = .shared) {
        self.models = models
    }

    static let automaticClusteringPolicy = AutomaticSpeakerClusteringPolicy.conservative

    static func sdkConfiguration(for config: DiarizationConfig) -> DiarizerConfig {
        var settings = DiarizerConfig.default
        settings.minSpeechDuration = Float(config.minSpeechDuration)
        settings.minSilenceGap = Float(config.pauseThreshold)
        settings.debugMode = false
        // numClusters stays -1: neither a calendar count nor fixture truth fixes it.
        return settings
    }

    static func applyAutomaticClusteringPolicy(to manager: DiarizerManager) {
        manager.speakerManager.speakerThreshold = automaticClusteringPolicy.maximumAssignmentCosineDistance
    }

    public func diarize(samples: [Float], config: DiarizationConfig) async throws -> [TrainedSpeakerSegment] {
        guard models.diarizationReadiness().ready else {
            throw SpeechModelsError.missingDiarizationModels
        }
        try models.validateDiarizationModels()
        guard samples.allSatisfy(\.isFinite) else { throw SpeechModelsError.invalidAudio }
        guard !samples.isEmpty else { return [] }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let bundles = try DiarizerModels.load(
            localSegmentationModel: models.segmentationModelURL,
            localEmbeddingModel: models.embeddingModelURL,
            configuration: configuration
        )
        let manager = DiarizerManager(config: Self.sdkConfiguration(for: config))
        Self.applyAutomaticClusteringPolicy(to: manager)
        manager.initialize(models: bundles)
        defer { manager.cleanup() }
        try Task.checkCancellation()
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        try Task.checkCancellation()
        return result.segments.map {
            TrainedSpeakerSegment(speakerID: $0.speakerId, start: Double($0.startTimeSeconds),
                                  end: Double($0.endTimeSeconds), embedding: $0.embedding)
        }
    }
}
