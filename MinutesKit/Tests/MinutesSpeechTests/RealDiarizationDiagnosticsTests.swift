import Foundation
import CoreML
import FluidAudio
import Testing
@testable import MinutesSpeech

/// Explicitly opt-in, synthetic-only investigation. Loads installed weights without
/// setup/download APIs, never invokes ASR, and reports distances rather than vectors.
@Suite("Installed-model diarization diagnostics", .serialized)
struct RealDiarizationDiagnosticsTests {
    private struct Truth: Decodable { let turns: [Turn] }
    private struct Turn: Decodable { let voice: String; let start: Double; let end: Double }

    @Test("Automatic clustering uses distance units and never fixes the speaker count")
    func conservativeAutomaticPolicy() {
        let settings = FluidDiarizationBackend.sdkConfiguration(for: MinutesSpeech.DiarizationConfig())
        let manager = DiarizerManager(config: settings)
        FluidDiarizationBackend.applyAutomaticClusteringPolicy(to: manager)
        #expect(manager.speakerManager.speakerThreshold == 0.65)
        #expect(settings.clusteringThreshold == DiarizerConfig.default.clusteringThreshold)
        #expect(settings.numClusters == -1)
        #expect(settings.debugMode == false)
    }

    @Test("Synthetic alternating turns: automatic clustering and clean-voice distances",
          .enabled(if: ProcessInfo.processInfo.environment["MINUTES_DIARIZATION_DIAGNOSTICS"] == "1"))
    func alternatingSyntheticVoices() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["MINUTES_DIARIZATION_FIXTURE_DIRECTORY"] ?? "/private/tmp/minutes-extended-speech")
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: directory.appendingPathComponent("ground-truth.json")))
        #expect(truth.turns.count == 18)
        let models = ModelManager.shared
        try models.validateDiarizationModels()
        let audio = try AudioDecoder.decode(fileURL: directory.appendingPathComponent("minutes-two-speaker-long.wav"), targetSampleRate: 16_000)
        let extraction = try manager(models: models, conservative: false)
        var embeddings: [[Float]] = []
        for index in truth.turns.indices {
            let clean = try AudioDecoder.decode(fileURL: directory.appendingPathComponent(String(format: "turn-%02d.wav", index)), targetSampleRate: 16_000)
            let vector = try extraction.extractSpeakerEmbedding(from: clean.samples)
            #expect(vector.count == 256 && vector.allSatisfy(\.isFinite))
            embeddings.append(vector)
        }
        extraction.cleanup()
        var within: [Double] = [], between: [Double] = []
        for i in embeddings.indices {
            for j in embeddings.indices where j > i {
                let value = cosineDistance(embeddings[i], embeddings[j])
                if truth.turns[i].voice == truth.turns[j].voice { within.append(value) }
                else { between.append(value) }
            }
        }
        emit(["kind": "clean_turn_distances", "turns": embeddings.count,
              "within_voice": statistics(within), "between_voices": statistics(between)])
        // Compare the manager default with the standalone SpeakerManager's
        // documented 0.65 assignment distance. No expected count is supplied.
        for conservative in [false, true] {
            let diarizer = try manager(models: models, conservative: conservative)
            let assignmentDistance = diarizer.speakerManager.speakerThreshold
            let start = Date()
            let result = try diarizer.performCompleteDiarization(audio.samples, sampleRate: 16_000)
            diarizer.cleanup()
            let labels = truth.turns.map { turn in
                var overlap: [String: Double] = [:]
                for segment in result.segments {
                    let duration = max(0, min(turn.end, Double(segment.endTimeSeconds)) - max(turn.start, Double(segment.startTimeSeconds)))
                    overlap[segment.speakerId, default: 0] += duration
                }
                return overlap.filter { $0.value > 0 }.max { $0.value < $1.value }?.key ?? "uncovered"
            }
            var merged = 0, split = 0, total = 0
            for i in labels.indices {
                for j in labels.indices where j > i {
                    total += 1
                    if truth.turns[i].voice != truth.turns[j].voice && labels[i] == labels[j] { merged += 1 }
                    if truth.turns[i].voice == truth.turns[j].voice && labels[i] != labels[j] { split += 1 }
                }
            }
            let speakerDetails: [[String: Any]] = Set(result.segments.map(\.speakerId)).sorted().map { id in
                let segments = result.segments.filter { $0.speakerId == id }
                let knownOverlap = segments.reduce(0.0) { sum, segment in
                    sum + truth.turns.reduce(0.0) { overlap, turn in
                        overlap + max(0, min(turn.end, Double(segment.endTimeSeconds)) - max(turn.start, Double(segment.startTimeSeconds)))
                    }
                }
                return ["id": id, "segments": segments.count,
                        "seconds": segments.reduce(0.0) { $0 + Double($1.endTimeSeconds - $1.startTimeSeconds) },
                        "known_speech_overlap": knownOverlap,
                        "first_start": Double(segments.first?.startTimeSeconds ?? 0),
                        "last_end": Double(segments.last?.endTimeSeconds ?? 0),
                        "distance_to_first_clean_voice": statistics(segments.map { cosineDistance($0.embedding, embeddings[0]) }),
                        "distance_to_second_clean_voice": statistics(segments.map { cosineDistance($0.embedding, embeddings[1]) })]
            }
            emit(["kind": "automatic_full_fixture", "speaker_details": speakerDetails, "policy": conservative ? "conservative_distance" : "sdk_default",
                  "assignment_cosine_distance": assignmentDistance,
                  "segments": result.segments.count, "speakers": Set(result.segments.map(\.speakerId)).count,
                  "turn_labels": labels, "merged_turn_pairs": merged, "split_turn_pairs": split,
                  "pairwise_agreement": Double(total - merged - split) / Double(total),
                  "seconds": Date().timeIntervalSince(start)])
            #expect(!result.segments.isEmpty)
            if conservative {
                #expect(merged == 0 && split == 0)
                #expect(!labels.contains("uncovered"))
                // Independent single-voice controls guard against a forced-count
                // solution: automatic diarization must retain one voice per clip.
                for index in 0...1 {
                    let clean = try AudioDecoder.decode(fileURL: directory.appendingPathComponent(String(format: "turn-%02d.wav", index)), targetSampleRate: 16_000)
                    let control = try manager(models: models, conservative: true)
                    let single = try control.performCompleteDiarization(clean.samples, sampleRate: 16_000)
                    control.cleanup()
                    let speakers = Set(single.segments.map(\.speakerId)).count
                    emit(["kind": "single_voice_control", "voice_index": index, "speakers": speakers, "segments": single.segments.count])
                    #expect(speakers == 1)
                }
            }
        }
    }
    private func manager(models: ModelManager, conservative: Bool) throws -> DiarizerManager {
        let compute = MLModelConfiguration(); compute.computeUnits = .cpuAndNeuralEngine
        let bundles = try DiarizerModels.load(localSegmentationModel: models.segmentationModelURL,
            localEmbeddingModel: models.embeddingModelURL, configuration: compute)
        let config = FluidDiarizationBackend.sdkConfiguration(for: MinutesSpeech.DiarizationConfig())
        let manager = DiarizerManager(config: config)
        if conservative { FluidDiarizationBackend.applyAutomaticClusteringPolicy(to: manager) }
        manager.initialize(models: bundles)
        return manager
    }
    private func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let a = lhs.reduce(0.0) { $0 + Double($1 * $1) }
        let b = rhs.reduce(0.0) { $0 + Double($1 * $1) }
        return 1 - dot / sqrt(a * b)
    }
    private func statistics(_ values: [Double]) -> [String: Double] {
        ["count": Double(values.count), "minimum": values.min() ?? 0, "maximum": values.max() ?? 0,
         "mean": values.reduce(0, +) / Double(max(values.count, 1))]
    }
    private func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data(("DIARIZATION_DIAGNOSTIC " + text + "\n").utf8))
    }
}
