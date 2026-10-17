import Foundation

/// Repairs display-only identifiers without overwriting an explicitly edited speaker name.
/// This assigns no person identity and changes no stored rows.
public enum TranscriptSpeakerLabels {
    private struct Key: Hashable {
        let meetingID: String
        let clusterID: String
    }

    public static func readableUtterances(_ utterances: [Utterance], clusters: [SpeakerCluster] = []) -> [Utterance] {
        var labels: [Key: String] = [:]
        for cluster in clusters {
            let label = cluster.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, label != cluster.id {
                labels[Key(meetingID: cluster.meetingId, clusterID: cluster.id)] = label
            }
        }
        var fallbackNumbers: [Key: Int] = [:]
        var counts: [String: Int] = [:]
        return utterances.map { utterance in
            var result = utterance
            let key = Key(meetingID: utterance.meetingId, clusterID: utterance.clusterId)
            if fallbackNumbers[key] == nil {
                counts[utterance.meetingId, default: 0] += 1
                fallbackNumbers[key] = counts[utterance.meetingId]
            }
            let name = utterance.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
            // Even a generic-looking explicit override belongs to the user.
            guard name.isEmpty || name == utterance.clusterId else { return result }
            result.speakerName = labels[key] ?? (utterance.clusterId.isEmpty ? "Unknown speaker" : "Speaker \(fallbackNumbers[key] ?? 1)")
            return result
        }
    }
}
