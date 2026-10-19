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

/// Post-pass over the SDK's streaming clusters, which drift: a 37-minute call
/// produced 24 call "speakers" for about 4 voices. Substantial clusters merge
/// only when nearly identical (one voice split by drift measured 0.155; two
/// people alternating turns over call audio measured 0.41). Fragments carry
/// too little audio for a reliable embedding, so, as pyannote's
/// min_cluster_size does, each joins its most similar substantial cluster on
/// the same track. A short speaker (a sentence or two) stays separate only
/// when unlike every substantial voice: on that call, short clusters measured
/// 0.60-0.97 from the main voices, so a lower bound would split ~9 more.
struct SpeakerConsolidationPolicy: Sendable {
    let minimumDistinctSpeakerSeconds: Double
    let maximumDuplicateCosineDistance: Float
    let minimumShortSpeakerSeconds: Double
    let minimumShortSpeakerCosineDistance: Float
    static let standard = Self(minimumDistinctSpeakerSeconds: 5, maximumDuplicateCosineDistance: 0.25,
                               minimumShortSpeakerSeconds: 2, minimumShortSpeakerCosineDistance: 0.9)

    /// Maps each input id to the id that survives. Inputs are unit centroids.
    func canonicalIDs(_ clusters: [(id: String, centroid: [Float], seconds: Double)]) -> [String: String] {
        var mapping = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0.id) })
        // Groups hold speech-weighted sums so merged centroids favour longer speech.
        var groups = clusters.filter { $0.seconds >= minimumDistinctSpeakerSeconds }
            .map { cluster in (id: cluster.id, sum: cluster.centroid.map { $0 * Float(cluster.seconds) }, seconds: cluster.seconds) }
        guard !groups.isEmpty else { return mapping }
        func distance(_ a: [Float], _ b: [Float]) -> Float {
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
            return 1 - dot / max(1e-9, (na * nb).squareRoot())
        }
        while groups.count > 1 {
            var best: (i: Int, j: Int, d: Float)?
            for i in groups.indices { for j in groups.indices where j > i {
                let d = distance(groups[i].sum, groups[j].sum)
                if d <= maximumDuplicateCosineDistance, d < (best?.d ?? .infinity) { best = (i, j, d) }
            } }
            guard let best else { break }
            // The longer cluster keeps its id; the shorter one's speech joins it.
            let (keep, drop) = groups[best.i].seconds >= groups[best.j].seconds ? (best.i, best.j) : (best.j, best.i)
            for k in groups[keep].sum.indices { groups[keep].sum[k] += groups[drop].sum[k] }
            groups[keep].seconds += groups[drop].seconds
            for (id, target) in mapping where target == groups[drop].id { mapping[id] = groups[keep].id }
            groups.remove(at: drop)
        }
        for cluster in clusters where cluster.seconds < minimumDistinctSpeakerSeconds {
            let nearest = groups.min { distance(cluster.centroid, $0.sum) < distance(cluster.centroid, $1.sum) }!
            let isDistinctShortSpeaker = cluster.seconds >= minimumShortSpeakerSeconds
                && distance(cluster.centroid, nearest.sum) >= minimumShortSpeakerCosineDistance
            if !isDistinctShortSpeaker { mapping[cluster.id] = nearest.id }
        }
        return mapping
    }
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
