import Foundation
import CryptoKit
import Testing
@testable import MinutesCore
@testable import MinutesSpeech

/// Tests only the SDK boundary conversion; these values make no accuracy claim.
struct FixtureDiarizationBackend: SpeakerDiarizationBackend {
    let output: [TrainedSpeakerSegment]
    init(output: [TrainedSpeakerSegment]? = nil) {
        var first = [Float](repeating: 0, count: 256)
        var second = first
        first[0] = 1
        second[1] = 1
        self.output = output ?? [
            TrainedSpeakerSegment(speakerID: "one", start: 0, end: 2, embedding: first),
            TrainedSpeakerSegment(speakerID: "two", start: 2, end: 4, embedding: second)
        ]
    }
    func diarize(samples: [Float], config: DiarizationConfig) async throws -> [TrainedSpeakerSegment] { output }
}

@Suite("Trained speaker backend boundary, without model weights")
struct TrainedDiarizationTests {
    @Test("Missing models fail locally and never create a model cache")
    func missingModels() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = ModelManager(modelsDirectory: path)
        #expect(!models.diarizationReadiness().ready)
        let service = DiarizationService(backend: FluidDiarizationBackend(models: models))
        do {
            _ = try await service.diarize(samples: [Float](repeating: 0, count: 16_000), meetingId: "missing")
            Issue.record("Missing models returned diarization")
        } catch SpeechModelsError.missingDiarizationModels {}
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(models.getInstalledModels().last?.sizeBytes == 0)
        #expect(models.getInstalledModels().last?.isOfflineReady == false)
    }

    @Test("Corrupt installed bytes fail before Core ML and are never redownloaded")
    func corruptModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(modelsDirectory: root)
        for bundle in [manager.segmentationModelURL, manager.embeddingModelURL] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("invalid model bytes".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        let marker: [String: Any] = ["model": SpeakerEmbeddingModel.trainedID,
                                    "hashes": ["wespeaker_v2.mlmodelc/coremldata.bin": "different hash"],
                                    "byteCount": 38]
        try JSONSerialization.data(withJSONObject: marker).write(to: manager.modelsDirectory.appendingPathComponent("minutes-model-integrity.json"))
        do {
            _ = try await FluidDiarizationBackend(models: manager).diarize(samples: [0], config: DiarizationConfig())
            Issue.record("Corrupt model bytes reached inference")
        } catch SpeechModelsError.missingDiarizationModels {}
        #expect(try Data(contentsOf: manager.embeddingModelURL.appendingPathComponent("coremldata.bin")) == Data("invalid model bytes".utf8))
    }

    @Test("Model integrity uses canonical relative paths through the tmp symlink")
    func canonicalModelPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/minutes-integrity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(modelsDirectory: root)
        let bytes = Data("fixture bytes for hashing only".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var hashes: [String: String] = [:]
        for bundle in [manager.segmentationModelURL, manager.embeddingModelURL] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try bytes.write(to: bundle.appendingPathComponent("coremldata.bin"))
            hashes[bundle.lastPathComponent + "/coremldata.bin"] = digest
        }
        let marker: [String: Any] = ["model": SpeakerEmbeddingModel.trainedID,
                                    "hashes": hashes, "byteCount": bytes.count * 2]
        try JSONSerialization.data(withJSONObject: marker).write(to: manager.modelsDirectory.appendingPathComponent("minutes-model-integrity.json"))
        try manager.validateDiarizationModels()
    }

    @Test("Converted model output has provenance and no invented identity confidence")
    func convertsModelOutput() async throws {
        let service = DiarizationService(backend: FixtureDiarizationBackend())
        let result = try await service.diarize(samples: [Float](repeating: 0, count: 64_000), meetingId: "meeting")
        #expect(result.clusters.count == 2)
        #expect(result.segments.count == 2)
        #expect(result.speechDuration == 4)
        #expect(result.segments[0].embedding[0] == 1)
        #expect(result.segments[1].embedding[1] == 1)
        for cluster in result.clusters {
            #expect(cluster.embeddingModel == SpeakerEmbeddingModel.trainedID)
            #expect(cluster.assignment == "unassigned")
            #expect(cluster.personId == nil)
            #expect(cluster.confidence == 0)
            #expect(cluster.centroid.count == 256)
        }
    }

    @Test("Invalid model vectors cannot become saved voiceprints")
    func invalidVectors() async throws {
        let backend = FixtureDiarizationBackend(output: [
            TrainedSpeakerSegment(speakerID: "bad", start: 0, end: 1, embedding: [Float](repeating: 0, count: 256))
        ])
        do {
            _ = try await DiarizationService(backend: backend).diarize(samples: [Float](repeating: 0, count: 16_000), meetingId: "invalid")
            Issue.record("Zero vector was accepted as a speaker embedding")
        } catch SpeechModelsError.invalidDiarizationOutput {}
    }

    @Test("Padded timestamps are clipped and overlapping speech is counted once")
    func clipsAndCountsOverlap() async throws {
        var vector = [Float](repeating: 0, count: 256)
        vector[0] = 1
        let backend = FixtureDiarizationBackend(output: [
            TrainedSpeakerSegment(speakerID: "one", start: 0, end: 3, embedding: vector),
            TrainedSpeakerSegment(speakerID: "two", start: 1, end: 6, embedding: vector)
        ])
        let result = try await DiarizationService(backend: backend).diarize(samples: [Float](repeating: 0, count: 64_000), meetingId: "overlap")
        #expect(result.segments[1].end == 4)
        #expect(result.speechDuration == 4)
    }
}

@Suite("Opt-in trained model inference")
struct TrainedModelSmokeTests {
    @Test("Explicit setup and actual public-fixture inference use isolated model storage",
          .enabled(if: ProcessInfo.processInfo.environment["MINUTES_MODELS"] == "1"))
    func publicFixtureInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelPath = try #require(environment["MINUTES_MODELS_DIR"])
        let fixturePath = try #require(environment["MINUTES_AUDIO_FIXTURE"])
        // Opt-in model runs must never silently use the user's normal cache.
        let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
        #expect(modelURL.path.hasPrefix("/private/tmp/") || modelURL.path.hasPrefix("/tmp/"))
        guard modelURL.path.hasPrefix("/private/tmp/") || modelURL.path.hasPrefix("/tmp/") else { return }
        let manager = ModelManager(modelsDirectory: modelURL)
        if environment["MINUTES_SETUP_MODELS"] == "1" {
            try await manager.setupDiarizationModels()
        }
        try manager.validateDiarizationModels()
        let decoded = try AudioDecoder.decode(fileURL: URL(fileURLWithPath: fixturePath), targetSampleRate: 16_000)
        let result = try await DiarizationService(backend: FluidDiarizationBackend(models: manager)).diarize(
            samples: decoded.samples, sampleRate: decoded.sampleRate, meetingId: "public-model-smoke")
        #expect(!result.segments.isEmpty)
        #expect(!result.clusters.isEmpty)
        #expect(result.speechDuration > 0)
        #expect(result.speechDuration <= decoded.duration)
        for cluster in result.clusters {
            #expect(cluster.embeddingModel == SpeakerEmbeddingModel.trainedID)
            #expect(cluster.centroid.count == 256)
            #expect(cluster.centroid.allSatisfy { $0.isFinite })
            #expect(cluster.assignment == "unassigned")
        }
        for segment in result.segments {
            #expect(segment.start >= 0)
            #expect(segment.end <= decoded.duration)
        }
    }
}
