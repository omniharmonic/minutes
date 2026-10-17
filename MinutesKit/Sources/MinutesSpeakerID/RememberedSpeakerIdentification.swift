import Foundation
import MinutesCore

public struct IdentifiedMeetingSpeakers: Sendable {
    public let clusters: [SpeakerCluster]
    public let utterances: [Utterance]
}

/// Prefills strong remembered matches while retaining model provenance and review.
/// Never creates people or enrolls voices. Supply persisted consented voiceprints,
/// not generated or provisional speaker centroids presented as learned profiles.
public enum RememberedSpeakerIdentification {
    public static func apply(clusters: [SpeakerCluster], utterances: [Utterance],
                             people: [Person], voiceprints: [Voiceprint],
                             existingClusters: [SpeakerCluster] = [],
                             attendeePersonIDs: Set<String> = []) -> IdentifiedMeetingSpeakers {
        let matcher = SpeakerMatcher(autoThreshold: 0.88, suggestThreshold: 0.88, attendeeBonus: 0,
                                     allowAutomaticAssignment: true, minimumMargin: 0.12)
        var updatedClusters = clusters
        var names: [String: String] = [:]
        for index in updatedClusters.indices {
            var cluster = updatedClusters[index]
            // An index/label is not identity. Preserve a persisted human decision
            // only when the complete compatible acoustic evidence is unchanged.
            if cluster.embeddingModel == SpeakerEmbeddingModel.trainedID,
               cluster.centroid.count == 256, cluster.centroid.allSatisfy(\.isFinite),
               VectorMath.l2Norm(cluster.centroid) > 1e-12,
               let previous = existingClusters.first(where: {
                   ($0.assignment == "user" || $0.assignment == "unknown") &&
                   $0.id == cluster.id && $0.meetingId == cluster.meetingId && $0.trackId == cluster.trackId &&
                   $0.embeddingModel == cluster.embeddingModel && $0.centroid == cluster.centroid &&
                   $0.speechSeconds == cluster.speechSeconds
               }) {
                cluster.label = previous.label
                cluster.personId = previous.personId
                cluster.assignment = previous.assignment
                cluster.confidence = previous.confidence
                updatedClusters[index] = cluster
                names[cluster.id] = cluster.label
                continue
            }
            // Explicit user choices survive processing refreshes and prefill attempts.
            guard cluster.assignment != "user", cluster.assignment != "unknown" else {
                names[cluster.id] = cluster.label
                continue
            }
            // Match individually: diarization can split one person's voice into several clusters.
            guard let match = matcher.match(clusters: [cluster], people: people, voiceprints: voiceprints,
                                            attendeePersonIds: attendeePersonIDs).first,
                  match.assignment == "auto", let personID = match.personId, let name = match.personName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            updatedClusters[index].personId = personID
            updatedClusters[index].label = name
            updatedClusters[index].assignment = "auto"
            updatedClusters[index].confidence = match.confidence // Similarity, not a calibrated probability.
            names[cluster.id] = name
        }
        var updatedUtterances = TranscriptSpeakerLabels.readableUtterances(utterances, clusters: updatedClusters)
        for index in updatedUtterances.indices {
            if let name = names[updatedUtterances[index].clusterId],
               updatedClusters.contains(where: { $0.id == updatedUtterances[index].clusterId && $0.meetingId == updatedUtterances[index].meetingId }) {
                updatedUtterances[index].speakerName = name
            }
        }
        return IdentifiedMeetingSpeakers(clusters: updatedClusters, utterances: updatedUtterances)
    }
}
