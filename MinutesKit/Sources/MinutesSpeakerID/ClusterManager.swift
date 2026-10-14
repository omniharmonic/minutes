import Foundation
import MinutesCore

public enum ClusterOperation: Sendable {
    case merge(sourceClusterIDs: [String], targetName: String)
    case split(clusterID: String, boundaryTimestamp: Double)
    case deleteVoiceprint(id: String)
}

public final class ClusterManager: Sendable {
    public init() {}
    
    /// Merges multiple speaker clusters into a single unified cluster.
    /// Centroid is calculated via weighted average followed by L2 normalization:
    /// c_bar = sum(w_i * c_i) / sum(w_i), c_hat = c_bar / ||c_bar||
    public func merge(
        clusters: [SpeakerCluster],
        targetName: String,
        newClusterId: String? = nil,
        personId: String? = nil
    ) -> SpeakerCluster {
        guard !clusters.isEmpty else {
            return SpeakerCluster(meetingId: "", trackId: "track_1", label: targetName)
        }
        
        let meetingId = clusters[0].meetingId
        let trackId = clusters[0].trackId
        let totalSpeechSeconds = clusters.reduce(0.0) { $0 + $1.speechSeconds }
        let id = newClusterId ?? ("merged_" + UUID().uuidString.prefix(6).lowercased())
        
        let vectors = clusters.map { $0.centroid }
        let weights = clusters.map { max(0.1, $0.speechSeconds) }
        let mergedCentroid = VectorMath.computeWeightedCentroid(vectors: vectors, weights: weights)
        
        let avgConfidence = clusters.reduce(0.0) { $0 + $1.confidence } / Double(clusters.count)
        
        return SpeakerCluster(
            id: id,
            meetingId: meetingId,
            trackId: trackId,
            label: targetName,
            centroid: mergedCentroid,
            speechSeconds: totalSpeechSeconds,
            personId: personId,
            assignment: "user",
            confidence: min(1.0, avgConfidence + 0.1)
        )
    }
    
    /// Splits a speaker cluster at a given timestamp boundary.
    /// Utterances starting before boundaryTimestamp are mapped to cluster 1;
    /// utterances starting at or after boundaryTimestamp are mapped to cluster 2.
    public func split(
        cluster: SpeakerCluster,
        boundaryTimestamp: Double,
        utterances: [Utterance]
    ) -> (cluster1: SpeakerCluster, cluster2: SpeakerCluster, updatedUtterances: [Utterance]) {
        let clusterUtterances = utterances.filter { $0.clusterId == cluster.id }
        let before = clusterUtterances.filter { $0.start < boundaryTimestamp }
        let after = clusterUtterances.filter { $0.start >= boundaryTimestamp }
        
        let dur1 = before.reduce(0.0) { $0 + ($1.end - $1.start) }
        let dur2 = after.reduce(0.0) { $0 + ($1.end - $1.start) }
        
        let id1 = cluster.id + "_part1"
        let id2 = cluster.id + "_part2"
        let label1 = "\(cluster.label) (Part 1)"
        let label2 = "\(cluster.label) (Part 2)"
        
        // Derive distinctive sub-centroids from original centroid
        var centroid1 = cluster.centroid
        var centroid2 = cluster.centroid
        if !cluster.centroid.isEmpty {
            for i in 0..<centroid1.count {
                if i % 2 == 0 {
                    centroid1[i] += 0.02
                    centroid2[i] -= 0.02
                } else {
                    centroid1[i] -= 0.02
                    centroid2[i] += 0.02
                }
            }
            centroid1 = VectorMath.l2Normalize(centroid1)
            centroid2 = VectorMath.l2Normalize(centroid2)
        }
        
        let c1 = SpeakerCluster(
            id: id1,
            meetingId: cluster.meetingId,
            trackId: cluster.trackId,
            label: label1,
            centroid: centroid1,
            speechSeconds: max(0.1, dur1),
            personId: cluster.personId,
            assignment: "user",
            confidence: cluster.confidence
        )
        
        let c2 = SpeakerCluster(
            id: id2,
            meetingId: cluster.meetingId,
            trackId: cluster.trackId,
            label: label2,
            centroid: centroid2,
            speechSeconds: max(0.1, dur2),
            personId: nil,
            assignment: "user",
            confidence: cluster.confidence
        )
        
        // Update utterance attributions
        var updated = utterances
        for i in 0..<updated.count {
            if updated[i].clusterId == cluster.id {
                if updated[i].start < boundaryTimestamp {
                    updated[i].clusterId = id1
                    updated[i].speakerName = label1
                } else {
                    updated[i].clusterId = id2
                    updated[i].speakerName = label2
                }
            }
        }
        
        return (c1, c2, updated)
    }
}
