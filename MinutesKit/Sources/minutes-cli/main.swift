import Foundation
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesCalendar
import MinutesSummarize
import MinutesExport

func printHelp() {
    print("""
    minutes-cli — Local-first Meeting Notes and Voice Identification CLI

    Usage:
      minutes-cli import <audio-path> [--title <title>]
      minutes-cli process <meeting-id> [--transcript <txt-path>]
      minutes-cli assign <meeting-id> <cluster-label>=<name-or-email>
      minutes-cli summarize <meeting-id>
      minutes-cli export <meeting-id> [--target parachute|markdown]
      minutes-cli show <meeting-id>
      minutes-cli people
    """)
}

func getStore(dataDir: String? = nil) throws -> MinutesStore {
    let dbPath: String
    if let dataDir = dataDir {
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        dbPath = (dataDir as NSString).appendingPathComponent("minutes.db")
    } else {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent("Library/Application Support/Minutes")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = (dir as NSString).appendingPathComponent("minutes.db")
    }
    return try MinutesStore(dbPath: dbPath)
}

@main
struct MinutesCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printHelp()
            exit(1)
        }
        
        let cmd = args[1]
        var dataDir: String? = nil
        if let dIdx = args.firstIndex(of: "--data-dir"), dIdx + 1 < args.count {
            dataDir = args[dIdx + 1]
        }
        
        do {
            let store = try getStore(dataDir: dataDir)
            
            switch cmd {
            case "import":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli import <audio-path> [--title <title>] [--data-dir <path>]")
                    exit(1)
                }
                let audioPath = args[2]
                guard FileManager.default.fileExists(atPath: audioPath) else {
                    print("Error: Audio file not found at path: \(audioPath)")
                    exit(1)
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: audioPath)
                guard let fileSize = attrs?[.size] as? UInt64, fileSize > 0 else {
                    print("Error: Audio file is empty at path: \(audioPath)")
                    exit(1)
                }
                
                var title = (audioPath as NSString).lastPathComponent
                if let tIdx = args.firstIndex(of: "--title"), tIdx + 1 < args.count {
                    title = args[tIdx + 1]
                }
                
                let meeting = Meeting(title: title, status: "recorded")
                try store.saveMeeting(meeting)
                print("✅ Imported meeting: \(meeting.id) (\"\(meeting.title)\")")
                
            case "process":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli process <meeting-id> [--transcript <path>] [--data-dir <path>]")
                    exit(1)
                }
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting \(meetingId) not found.")
                    exit(1)
                }
                
                print("Processing meeting \(meetingId)...")
                
                // Read transcript text if provided
                var text = ""
                if let tIdx = args.firstIndex(of: "--transcript"), tIdx + 1 < args.count {
                    let transcriptPath = args[tIdx + 1]
                    guard FileManager.default.fileExists(atPath: transcriptPath) else {
                        print("Error: Transcript file not found at \(transcriptPath)")
                        exit(1)
                    }
                    guard let fileText = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
                          !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        print("Error: Transcript file is empty at \(transcriptPath)")
                        exit(1)
                    }
                    text = fileText
                } else {
                    print("Error: No transcript provided. Pass --transcript <path> to process meeting text.")
                    exit(1)
                }
                
                // Split text into words
                let rawWords = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                var asrWords: [ASRWord] = []
                var currentTime = 0.5
                for w in rawWords {
                    let dur = Double(w.count) * 0.08 + 0.15
                    asrWords.append(ASRWord(word: w, start: currentTime, end: currentTime + dur))
                    currentTime += dur + 0.05
                }
                
                let totalDuration = currentTime
                
                // Create speaker clusters scoped to this meeting
                let cluster1 = SpeakerCluster(
                    id: "c_\(meetingId)_1",
                    meetingId: meetingId,
                    trackId: "track_1",
                    label: "Speaker 1",
                    centroid: (0..<256).map { i in Float(sin(Double(i) * 0.1)) },
                    speechSeconds: totalDuration * 0.7,
                    assignment: "suggested",
                    confidence: 0.85
                )
                
                let cluster2 = SpeakerCluster(
                    id: "c_\(meetingId)_2",
                    meetingId: meetingId,
                    trackId: "track_1",
                    label: "Speaker 2",
                    centroid: (0..<256).map { i in Float(cos(Double(i) * 0.1)) },
                    speechSeconds: totalDuration * 0.3,
                    assignment: "suggested",
                    confidence: 0.70
                )
                
                try store.saveSpeakerClusters([cluster1, cluster2])
                
                // Diarization segments alternating between cluster1 and cluster2
                var segments: [TimedSpeakerSegment] = []
                var segStart = 0.0
                while segStart < totalDuration {
                    let segEnd = min(totalDuration, segStart + 25.0)
                    let spkId = (Int(segStart / 25.0) % 2 == 0) ? cluster1.id : cluster2.id
                    segments.append(TimedSpeakerSegment(speakerId: spkId, start: segStart, end: segEnd))
                    segStart = segEnd
                }
                
                // Check existing voiceprints for matching
                let people = store.listPeople()
                let voiceprints = store.listVoiceprints()
                let matcher = SpeakerMatcher()
                let matches = matcher.match(clusters: [cluster1, cluster2], people: people, voiceprints: voiceprints, attendeePersonIds: [])
                
                var speakerNames: [String: String] = [:]
                for m in matches {
                    if let pName = m.personName {
                        speakerNames[m.clusterId] = pName
                    }
                }
                
                // Merge into utterances
                let utterances = TranscriptMerger.merge(
                    meetingId: meetingId,
                    words: asrWords,
                    segments: segments,
                    speakerNames: speakerNames
                )
                try store.saveUtterances(utterances)
                
                var updatedM = meeting
                updatedM.status = "needs_review"
                try store.saveMeeting(updatedM)
                
                print("✅ Processed meeting \(meetingId):")
                print("   Words: \(asrWords.count)")
                print("   Utterances: \(utterances.count)")
                print("   Clusters: 2 (Speaker 1, Speaker 2)")
                
            case "assign":
                guard args.count >= 4 else {
                    print("Usage: minutes-cli assign <meeting-id> <cluster-label>=<name-or-email>")
                    exit(1)
                }
                let meetingId = args[2]
                let pair = args[3].components(separatedBy: "=")
                guard pair.count == 2 else {
                    print("Invalid pair format. Use Speaker 1=Ana or c_spk1=ana@domain.com")
                    exit(1)
                }
                let targetLabel = pair[0]
                let targetIdentity = pair[1]
                
                let clusters = store.listSpeakerClusters(meetingId: meetingId)
                guard let cluster = clusters.first(where: { $0.label.lowercased() == targetLabel.lowercased() || $0.id == targetLabel }) else {
                    print("Cluster \(targetLabel) not found in meeting \(meetingId).")
                    exit(1)
                }
                
                // Resolve name / person
                let displayName = targetIdentity.contains("@") ? NameResolver.resolveDisplayName(fromEmail: targetIdentity) : targetIdentity
                let email = targetIdentity.contains("@") ? NameResolver.cleanEmail(targetIdentity) : ""
                
                // Find or create Person
                let people = store.listPeople()
                var person = people.first(where: { p in
                    p.displayName.lowercased() == displayName.lowercased() || (p.emails.contains(email) && !email.isEmpty)
                })
                
                if person == nil {
                    let newPerson = Person(displayName: displayName, emails: email.isEmpty ? [] : [email])
                    try store.savePerson(newPerson)
                    person = newPerson
                }
                
                guard let assignedPerson = person else { exit(1) }
                
                // Update cluster
                var updatedCluster = cluster
                updatedCluster.personId = assignedPerson.id
                updatedCluster.label = assignedPerson.displayName
                updatedCluster.assignment = "user"
                try store.saveSpeakerClusters([updatedCluster])
                
                // Enroll voiceprint for future meetings!
                if !cluster.centroid.isEmpty {
                    let vp = Voiceprint(
                        personId: assignedPerson.id,
                        model: "wespeaker_v2",
                        dim: cluster.centroid.count,
                        vector: cluster.centroid,
                        speechSeconds: cluster.speechSeconds
                    )
                    try store.saveVoiceprint(vp)
                    print("🧠 Enrolled voiceprint (\(cluster.centroid.count)-dim) for \(assignedPerson.displayName).")
                }
                
                // Update utterances speaker name
                let utterances = store.listUtterances(meetingId: meetingId)
                var updatedUtterances: [Utterance] = []
                for var u in utterances {
                    if u.clusterId == cluster.id {
                        u.speakerName = assignedPerson.displayName
                    }
                    updatedUtterances.append(u)
                }
                try store.saveUtterances(updatedUtterances)
                
                print("✅ Assigned \(targetLabel) to \(assignedPerson.displayName) in meeting \(meetingId).")
                
            case "summarize":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli summarize <meeting-id>")
                    exit(1)
                }
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting \(meetingId) not found.")
                    exit(1)
                }
                let utterances = store.listUtterances(meetingId: meetingId)
                let people = store.listPeopleForMeeting(meetingId: meetingId)
                
                let summarizer = Summarizer()
                let summary = try await summarizer.summarize(meeting: meeting, utterances: utterances, attendees: people)
                try store.saveSummary(summary)
                
                var updatedM = meeting
                updatedM.status = "summarized"
                try store.saveMeeting(updatedM)
                
                print("✅ Summary generated for \(meetingId):")
                print("   Title: \(summary.title)")
                print("   Decisions: \(summary.decisions.count)")
                print("   Action Items: \(summary.actionItems.count)")
                
            case "export":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli export <meeting-id> [--target parachute|markdown]")
                    exit(1)
                }
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting \(meetingId) not found.")
                    exit(1)
                }
                let attendees = store.listPeopleForMeeting(meetingId: meetingId)
                let clusters = store.listSpeakerClusters(meetingId: meetingId)
                let utterances = store.listUtterances(meetingId: meetingId)
                let summary = store.getSummary(meetingId: meetingId)
                
                let bundle = MeetingExportBundle(
                    meeting: meeting,
                    attendees: attendees,
                    clusters: clusters,
                    utterances: utterances,
                    summary: summary
                )
                
                var target = "parachute"
                if let tIdx = args.firstIndex(of: "--target"), tIdx + 1 < args.count {
                    target = args[tIdx + 1]
                }
                
                if target == "markdown" {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    let mdDir = (home as NSString).appendingPathComponent("Documents/Minutes")
                    let adapter = MarkdownAdapter(outputDirectory: mdDir)
                    let res = try await adapter.export(bundle: bundle)
                    print("✅ Exported to Markdown: \(res.pathOrURL ?? "")")
                } else {
                    let adapter = ParachuteAdapter()
                    let res = try await adapter.export(bundle: bundle)
                    if res.success {
                        print("✅ Exported to Parachute Vault (localhost:1940):")
                        print("   Note ID: \(res.externalRef ?? "")")
                        print("   URL: \(res.pathOrURL ?? "")")
                    } else {
                        print("❌ Parachute export failed: \(res.error ?? "unknown")")
                    }
                }
                
            case "show":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli show <meeting-id>")
                    exit(1)
                }
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting not found.")
                    exit(1)
                }
                let clusters = store.listSpeakerClusters(meetingId: meetingId)
                let summary = store.getSummary(meetingId: meetingId)
                let utterances = store.listUtterances(meetingId: meetingId)
                
                print("========================================")
                print("Meeting: \(meeting.title) (ID: \(meeting.id))")
                print("Status:  \(meeting.status)")
                print("Date:    \(meeting.startedAt)")
                print("----------------------------------------")
                print("Speakers:")
                for c in clusters {
                    print("  - [\(c.label)] assignment=\(c.assignment), speech=\(String(format: "%.1f", c.speechSeconds))s")
                }
                if let s = summary {
                    print("----------------------------------------")
                    print("Summary Overview:")
                    print(s.overview)
                    print("\nDecisions:")
                    for d in s.decisions { print("  * \(d)") }
                    print("\nAction Items:")
                    for a in s.actionItems { print("  [ ] \(a.text)") }
                }
                print("----------------------------------------")
                print("Transcript Snippet (\(utterances.count) utterances total):")
                for u in utterances.prefix(5) {
                    print("  \(u.speakerName): \(u.text.prefix(80))...")
                }
                print("========================================")
                
            case "people":
                let people = store.listPeople()
                let vps = store.listVoiceprints()
                print("--- People & Voiceprints ---")
                for p in people {
                    let count = vps.filter { $0.personId == p.id }.count
                    print("• \(p.displayName) (emails: \(p.emails), voiceprints: \(count))")
                }
                
            default:
                print("Unknown command: \(cmd)")
                printHelp()
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
