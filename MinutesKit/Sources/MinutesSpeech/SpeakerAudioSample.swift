import Foundation
import MinutesCore

/// A bounded excerpt on the meeting's common timeline. Source captures use the
/// aligned channel so another speaker's overlapping audio does not mask it.
public struct SpeakerAudioSample: Sendable {
    public let start: Double
    public let end: Double

    public init?(utterances: [Utterance], clusterID: String) {
        let valid = utterances.filter {
            $0.clusterId == clusterID && $0.start.isFinite && $0.end.isFinite &&
            $0.start >= 0 && $0.end > $0.start
        }.sorted { $0.start < $1.start }
        guard let sample = valid.first(where: { $0.end - $0.start >= 2 && $0.end - $0.start <= 12 }) ?? valid.first else { return nil }
        start = sample.start
        end = min(sample.end, sample.start + 12)
    }

    public static func audioPath(meeting: Meeting, cluster: SpeakerCluster) throws -> String {
        guard meeting.platform != "transcript_import", let path = meeting.audioPath else {
            throw failure("This transcript has no recorded audio.")
        }
        if let sources = try CaptureSourceProcessing.sources(for: URL(fileURLWithPath: path)),
           cluster.trackId == "system" || cluster.trackId == "microphone" {
            guard let source = sources.first(where: { $0.0 == cluster.trackId }) else {
                throw failure("This speaker’s recorded audio source is unavailable.")
            }
            return source.1.path
        }
        return path
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SpeakerAudioSample", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
