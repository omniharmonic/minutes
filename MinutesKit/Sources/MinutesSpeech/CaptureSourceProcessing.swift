import Foundation
import MinutesCore

enum CaptureSourceProcessing {
    /// Only finalized Minutes captures have aligned, common-clock source files.
    static func sources(for processingURL: URL) throws -> [(String, URL)]? {
        guard processingURL.lastPathComponent == "mixed.caf" else { return nil }
        let root = processingURL.deletingLastPathComponent()
        let manifestURL = root.appendingPathComponent("capture.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1_048_576 else {
            throw ASRError.audioUnreadable("Capture metadata is too large; source audio is preserved.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureTimelineManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schema == "minutes.capture/1", manifest.clock == "SCStream.synchronizationClock",
              manifest.completed, manifest.issues.isEmpty, manifest.processingFile == "mixed.caf",
              manifest.tracks.contains(where: { $0.source == .system }),
              Set(manifest.tracks.map(\.source)).count == manifest.tracks.count else {
            throw ASRError.audioUnreadable("This capture has incomplete source metadata. Original audio is preserved.")
        }
        return try manifest.tracks.sorted { $0.source == .system && $1.source != .system }.map { track in
            let url = root.appendingPathComponent("aligned-\(track.source.rawValue).caf")
            guard track.file == "\(track.source.rawValue).caf", track.frameCount > 0,
                  url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ASRError.audioUnreadable("An aligned capture source is missing or invalid. Original audio is preserved.")
            }
            return (track.source.rawValue, url)
        }
    }

    static func merge(meetingID: String, results: [(String, PipelineResult)], skippedSources: [String] = []) -> PipelineResult {
        var clusters: [SpeakerCluster] = [], segments: [TimedSpeakerSegment] = [], utterances: [Utterance] = []
        var sourceByCluster: [String: String] = [:]
        for (source, result) in results {
            let ids = Dictionary(uniqueKeysWithValues: result.clusters.map { ($0.id, source + "_" + $0.id) })
            for cluster in result.clusters {
                let id = ids[cluster.id]!
                let assignedName = result.utterances.first(where: { $0.clusterId == cluster.id })?.speakerName ?? cluster.label
                let label = assignedName == cluster.label
                    ? (source == "system" ? "Call " : "Microphone ") + cluster.label.lowercased()
                    : assignedName
                clusters.append(SpeakerCluster(id: id, meetingId: meetingID, trackId: source, label: label,
                    centroid: cluster.centroid, speechSeconds: cluster.speechSeconds, personId: cluster.personId,
                    assignment: cluster.assignment, confidence: cluster.confidence, embeddingModel: cluster.embeddingModel))
                sourceByCluster[id] = source
            }
            segments += result.segments.map { .init(speakerId: ids[$0.speakerId] ?? source + "_" + $0.speakerId,
                start: $0.start, end: $0.end, embedding: $0.embedding) }
            for utterance in result.utterances {
                let tokens = normalizedWords(utterance.text)
                let duplicate = tokens.count >= 8 && utterances.contains { prior in
                    guard sourceByCluster[prior.clusterId] != source, normalizedWords(prior.text) == tokens else { return false }
                    let overlap = min(prior.end, utterance.end) - max(prior.start, utterance.start)
                    let duration = min(prior.end - prior.start, utterance.end - utterance.start)
                    return duration > 0 && overlap / duration >= 0.6
                }
                guard !duplicate else { continue }
                let clusterID = ids[utterance.clusterId] ?? source + "_" + utterance.clusterId
                let label = clusters.first(where: { $0.id == clusterID })?.label ?? utterance.speakerName
                utterances.append(Utterance(id: 0, meetingId: meetingID, clusterId: clusterID, speakerName: label,
                    start: utterance.start, end: utterance.end, text: utterance.text, words: utterance.words))
            }
        }
        let ordered = utterances.sorted { $0.start == $1.start ? $0.clusterId < $1.clusterId : $0.start < $1.start }
            .enumerated().map { index, utterance in
                Utterance(id: index + 1, meetingId: meetingID, clusterId: utterance.clusterId,
                    speakerName: utterance.speakerName, start: utterance.start, end: utterance.end,
                    text: utterance.text, words: utterance.words)
            }
        return PipelineResult(meetingId: meetingID, audioDuration: results.map { $0.1.audioDuration }.max() ?? 0,
            sampleRate: 16000, words: results.flatMap { $0.1.words }.sorted { $0.start < $1.start },
            segments: segments.sorted { $0.start < $1.start }, clusters: clusters, utterances: ordered,
            speechDuration: results.reduce(0) { $0 + $1.1.speechDuration },
            uncoveredSpeechSeconds: results.reduce(0) { $0 + $1.1.uncoveredSpeechSeconds },
            skippedSources: skippedSources)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
