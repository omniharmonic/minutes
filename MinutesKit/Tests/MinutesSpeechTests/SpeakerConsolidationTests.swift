import Foundation
import Testing
@testable import MinutesSpeech

/// Unit vector at `degrees` from the x axis; cosine distance between two is 1 - cos(Δ).
private func voice(_ degrees: Double) -> [Float] {
    var vector = [Float](repeating: 0, count: 256)
    vector[0] = Float(cos(degrees * .pi / 180)); vector[1] = Float(sin(degrees * .pi / 180))
    return vector
}

private actor SegmentsFixture: SpeakerDiarizationBackend {
    let output: [TrainedSpeakerSegment]
    init(_ output: [TrainedSpeakerSegment]) { self.output = output }
    func diarize(samples: [Float], config: DiarizationConfig) async throws -> [TrainedSpeakerSegment] { output }
}

struct SpeakerConsolidationTests {
    let policy = SpeakerConsolidationPolicy.standard

    @Test("A drifted duplicate merges; two alternating voices 0.41 apart stay distinct")
    func substantialClusters() {
        // 0.155 ≈ 32°, 0.41 ≈ 54°: the distances measured on the 37-minute call.
        let mapping = policy.canonicalIDs([
            (id: "a", centroid: voice(0), seconds: 900),
            (id: "b", centroid: voice(54), seconds: 330),
            (id: "a2", centroid: voice(-32), seconds: 10),
        ])
        #expect(mapping["a2"] == "a")
        #expect(mapping["b"] == "b")
    }

    @Test("Fragments join their most similar substantial voice even when far from all of them")
    func fragmentsJoinNearest() {
        let mapping = policy.canonicalIDs([
            (id: "a", centroid: voice(0), seconds: 900),
            (id: "b", centroid: voice(90), seconds: 330),
            (id: "f1", centroid: voice(70), seconds: 2.4),
            (id: "f2", centroid: voice(-60), seconds: 0.4),
        ])
        #expect(mapping["f1"] == "b")
        #expect(mapping["f2"] == "a")
        #expect(Set(mapping.values) == ["a", "b"])
    }

    @Test("A short recording with no substantial voice keeps every cluster")
    func shortRecordingUnchanged() {
        let mapping = policy.canonicalIDs([
            (id: "a", centroid: voice(0), seconds: 3),
            (id: "b", centroid: voice(90), seconds: 2),
        ])
        #expect(mapping == ["a": "a", "b": "b"])
    }

    @Test("Diarization output relabels fragment segments and sums their speech into the survivor")
    func diarizationAppliesConsolidation() async throws {
        let service = DiarizationService(backend: SegmentsFixture([
            .init(speakerID: "x", start: 0, end: 20, embedding: voice(0)),
            .init(speakerID: "y", start: 20, end: 30, embedding: voice(90)),
            .init(speakerID: "z", start: 30, end: 31, embedding: voice(80)),
        ]))
        let result = try await service.diarize(samples: [Float](repeating: 0, count: 16_000 * 32), meetingId: "m")
        #expect(result.clusters.count == 2)
        let fragment = try #require(result.segments.first { $0.start == 30 })
        let second = try #require(result.segments.first { $0.start == 20 })
        #expect(fragment.speakerId == second.speakerId)
        let survivor = try #require(result.clusters.first { $0.id == second.speakerId })
        #expect(abs(survivor.speechSeconds - 11) < 0.001)
        #expect(result.clusters.map(\.label).sorted() == ["Speaker 1", "Speaker 2"])
    }
}
