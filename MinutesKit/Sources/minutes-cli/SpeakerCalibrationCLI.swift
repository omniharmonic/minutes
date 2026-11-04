import Foundation
import MinutesCore
import MinutesSpeakerID

/// `minutes-cli speakers calibrate`: replays the person's own speaker decisions
/// against each automatic-naming preset. Read-only; prints counts, never vectors.
enum SpeakerCalibrationCLI {
    struct Tally { var correct = 0, wrong = 0, abstained = 0, impostorNamed = 0, impostorTrials = 0 }

    static func run(arguments: [String], store: MinutesStore) throws {
        guard arguments.count > 2, arguments[2] == "calibrate" else {
            print("Usage: minutes-cli speakers calibrate [--data-dir <path>]"); exit(1)
        }
        let people = store.listPeople()
        let voiceprints = store.listVoiceprints()
        // Ground truth: clusters a person named by hand, with a trained voice.
        var labeled: [(SpeakerCluster, Set<String>)] = []
        for meeting in store.listMeetings() {
            let attendees = Set(store.listPeopleForMeeting(meetingId: meeting.id).map(\.id))
            for cluster in store.listSpeakerClusters(meetingId: meeting.id)
            where cluster.assignment == "user" && cluster.personId != nil &&
                  cluster.embeddingModel == SpeakerEmbeddingModel.trainedID && cluster.centroid.count == 256 {
                labeled.append((cluster, attendees))
            }
        }
        print("\(labeled.count) hand-named speakers across the library; \(Set(voiceprints.map(\.personId)).count) people with remembered voices.")
        guard !labeled.isEmpty else { return }
        if arguments.contains("--detail") {
            // Scores only: same-person similarity vs. the closest other person.
            print("speech_s  same_person  closest_other")
            for (cluster, _) in labeled {
                let fair = voiceprints.filter { VectorMath.cosineSimilarity(cluster.centroid, $0.vector) < 0.995 }
                let same = fair.filter { $0.personId == cluster.personId }.map { VectorMath.cosineSimilarity(cluster.centroid, $0.vector) }.max()
                let other = fair.filter { $0.personId != cluster.personId }.map { VectorMath.cosineSimilarity(cluster.centroid, $0.vector) }.max()
                print(String(format: "%7.0f   %@   %@", cluster.speechSeconds,
                             same.map { String(format: "%.3f", $0) } ?? "  –  ", other.map { String(format: "%.3f", $0) } ?? "  –  "))
            }
        }
        let presets: [SpeakerAutoLabelPolicy] = [.preset(.cautious), .preset(.balanced), .preset(.eager)]
        print("preset     sim   margin | named right  named wrong  left unnamed | impostor named wrongly")
        for policy in presets {
            var tally = Tally()
            for (cluster, _) in labeled {
                guard let truth = cluster.personId else { continue }
                // A voiceprint made from this very cluster would match it trivially.
                let fair = voiceprints.filter { VectorMath.cosineSimilarity(cluster.centroid, $0.vector) < 0.995 }
                var probe = cluster
                probe.assignment = "unassigned"; probe.personId = nil
                if fair.contains(where: { $0.personId == truth }) {
                    let result = RememberedSpeakerIdentification.apply(clusters: [probe], utterances: [], people: people,
                                                                      voiceprints: fair, policy: policy).clusters[0]
                    if result.assignment != "auto" { tally.abstained += 1 }
                    else if result.personId == truth { tally.correct += 1 } else { tally.wrong += 1 }
                }
                // Impostor: this person has no remembered voice at all.
                let others = fair.filter { $0.personId != truth }
                if !others.isEmpty {
                    tally.impostorTrials += 1
                    let result = RememberedSpeakerIdentification.apply(clusters: [probe], utterances: [], people: people,
                                                                      voiceprints: others, policy: policy).clusters[0]
                    if result.assignment == "auto" { tally.impostorNamed += 1 }
                }
            }
            let trials = tally.correct + tally.wrong + tally.abstained
            func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "  –  " : String(format: "%5.1f%%", Double(n) * 100 / Double(d)) }
            print(String(format: "%-9@ %.2f  %.2f   |", policy.preset.rawValue as NSString, policy.similarity, policy.margin),
                  "\(pct(tally.correct, trials))      \(pct(tally.wrong, trials))       \(pct(tally.abstained, trials))     |",
                  "\(pct(tally.impostorNamed, tally.impostorTrials)) of \(tally.impostorTrials)")
        }
    }
}
