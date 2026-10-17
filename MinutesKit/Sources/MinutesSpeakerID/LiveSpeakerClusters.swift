import Foundation

/// Session-only anonymous grouping. Never enrolls a voice or asserts a person's identity.
public struct LiveSpeakerClusters: Sendable {
    private struct Entry: Sendable { let id: String; let vector: [Float] }
    private var entries: [Entry] = []
    public init() {}
    public mutating func label(for vector: [Float]) -> String? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite), VectorMath.l2Norm(vector) > 1e-12 else { return nil }
        let ranked = entries.map { ($0.id, VectorMath.cosineSimilarity(vector, $0.vector)) }.sorted { $0.1 > $1.1 }
        if let best = ranked.first, best.1 >= 0.90,
           ranked.count == 1 || best.1 - ranked[1].1 >= 0.12 { return best.0 }
        // Ambiguity creates a separate provisional group, never a forced merge.
        guard entries.count < 64 else { return nil }
        let id = "Speaker \(entries.count + 1)"
        entries.append(Entry(id: id, vector: VectorMath.l2Normalize(vector)))
        return id
    }
}
