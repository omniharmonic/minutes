import Foundation

/// Session-only anonymous grouping. Never enrolls a voice or asserts a person's identity.
///
/// Each group keeps a running average of its voice, so a new caption window is
/// compared with everything heard from that speaker rather than one sample.
/// Calibrated on a 2h10m three-speaker recording (docs/DECISIONS.md, 2026-10-21):
/// short windows of one voice score a median 0.74 with each other and different
/// voices 0.18, so the earlier 0.90 rule split one speaker into dozens of groups.
public struct LiveSpeakerClusters: Sendable {
    /// Join the closest group at or above this similarity to its average voice.
    public static let joinThreshold = 0.55
    /// Start a new group only below this; in between the window stays unnamed.
    public static let newGroupThreshold = 0.40
    /// Groups whose average voices reach this are one speaker and merge.
    public static let mergeThreshold = 0.65
    /// More than this is rarely a real call; extra voices stay unnamed.
    public static let maximumGroups = 12

    private struct Group: Sendable { let id: String; var sum: [Float]; var count: Int }
    private var groups: [Group] = []
    private var mergedInto: [String: String] = [:]
    public init() {}

    /// The group for this window's voice evidence, or nil when it is unclear.
    public mutating func label(for vector: [Float]) -> String? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite), VectorMath.l2Norm(vector) > 1e-12 else { return nil }
        let voice = VectorMath.l2Normalize(vector)
        let ranked = groups.indices.map { ($0, VectorMath.cosineSimilarity(voice, groups[$0].sum)) }.sorted { $0.1 > $1.1 }
        if let (index, similarity) = ranked.first, similarity >= Self.joinThreshold {
            for i in groups[index].sum.indices { groups[index].sum[i] += voice[i] }
            groups[index].count += 1
            let id = groups[index].id
            mergeSimilarGroups()
            return resolve(id)
        }
        // Ambiguous evidence stays unnamed rather than inventing a speaker.
        guard ranked.first.map({ $0.1 < Self.newGroupThreshold }) ?? true, groups.count < Self.maximumGroups else { return nil }
        let id = "Speaker \(groups.count + mergedInto.count + 1)"
        groups.append(Group(id: id, sum: voice, count: 1))
        return id
    }

    /// The current label for a label returned earlier; groups can merge later.
    public func resolve(_ label: String) -> String {
        var label = label
        while let next = mergedInto[label] { label = next }
        return label
    }

    private mutating func mergeSimilarGroups() {
        var merged = true
        while merged {
            merged = false
            search: for a in groups.indices { for b in groups.indices where b > a {
                guard VectorMath.cosineSimilarity(groups[a].sum, groups[b].sum) >= Self.mergeThreshold else { continue }
                // The longer-established group keeps its name.
                let (keep, drop) = groups[a].count >= groups[b].count ? (a, b) : (b, a)
                for i in groups[keep].sum.indices { groups[keep].sum[i] += groups[drop].sum[i] }
                groups[keep].count += groups[drop].count
                mergedInto[groups[drop].id] = groups[keep].id
                groups.remove(at: drop)
                merged = true
                break search
            } }
        }
    }
}
