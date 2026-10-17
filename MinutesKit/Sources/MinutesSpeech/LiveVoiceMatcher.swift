import Foundation
import AVFoundation
import MinutesCore
import MinutesSpeakerID

/// Disposable caption attribution; never writes profiles, people, or final transcripts.
public actor LiveVoiceMatcher {
    public struct Evaluation: Sendable {
        public let name: String?
        public let reason: String
        public init(name: String? = nil, reason: String) { self.name = name; self.reason = reason }
    }
    private let backend: any SpeakerDiarizationBackend
    public init(backend: any SpeakerDiarizationBackend = FluidDiarizationBackend()) { self.backend = backend }

    public func name(samples: [Float], rate: Double, people: [Person], voiceprints: [Voiceprint]) async throws -> String? {
        try await evaluate(samples: samples, rate: rate, people: people, voiceprints: voiceprints).name
    }
    public func evaluate(samples: [Float], rate: Double, people: [Person], voiceprints: [Voiceprint]) async throws -> Evaluation {
        guard rate.isFinite, rate >= 8_000, rate <= 192_000,
              samples.count >= Int(rate * 5), samples.count <= Int(rate * 15),
              samples.allSatisfy(\.isFinite), !voiceprints.isEmpty else { return Evaluation(reason: "insufficient-audio-or-profiles") }
        let mono = try Self.resample(samples, rate: rate)
        let segments = try await backend.diarize(samples: mono, config: DiarizationConfig())
        try Task.checkCancellation()
        // Do not label an entire caption window when a turn or overlap was detected.
        guard !segments.isEmpty, Set(segments.map(\.speakerID)).count == 1 else { return Evaluation(reason: "mixed-or-undetected-speech") }
        let duration = Double(mono.count) / 16_000
        var end = 0.0, speech = 0.0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= end,
                  segment.end > segment.start, segment.end <= duration + 0.05,
                  segment.embedding.count == 256, segment.embedding.allSatisfy(\.isFinite) else { return Evaluation(reason: "overlap-or-invalid-evidence") }
            speech += segment.end - segment.start; end = segment.end
        }
        guard speech >= 5 else { return Evaluation(reason: "insufficient-speech") }
        let centroid = VectorMath.computeWeightedCentroid(vectors: segments.map(\.embedding),
            weights: segments.map { $0.end - $0.start })
        guard segments.allSatisfy({ VectorMath.cosineSimilarity($0.embedding, centroid) >= 0.9 }) else { return Evaluation(reason: "inconsistent-voice") }
        let cluster = SpeakerCluster(meetingId: "live-preview", trackId: "preview", label: "Speaker",
            centroid: centroid, speechSeconds: speech, embeddingModel: SpeakerEmbeddingModel.trainedID)
        let result = SpeakerMatcher(autoThreshold: 0.9, suggestThreshold: 0.9, attendeeBonus: 0,
            allowAutomaticAssignment: true, minimumMargin: 0.12)
            .match(clusters: [cluster], people: people, voiceprints: voiceprints, attendeePersonIds: [])
        guard let match = result.first, match.assignment == "auto",
              let name = match.personName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Evaluation(reason: "weak-or-ambiguous-match") }
        return Evaluation(name: name, reason: "matched")
    }

    private static func resample(_ samples: [Float], rate: Double) throws -> [Float] {
        if rate == 16_000 { return samples }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / rate)) + 1024)
        else { throw SpeechModelsError.invalidAudio }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { throw SpeechModelsError.invalidAudio }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
