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
      minutes-cli import-transcript <text-path> [--title <title>]
      minutes-cli recover-audio <meeting-id> [--data-dir <path>]
      minutes-cli process <meeting-id>
      minutes-cli assign <meeting-id> <cluster-label>=<name-or-email> [--learn]
      minutes-cli summarize <meeting-id>
      minutes-cli export <meeting-id> [--target parachute|markdown] [--output-dir <directory>]
      minutes-cli find-transcript <meeting-id> <query> [--data-dir <path>]
      minutes-cli show <meeting-id>
      minutes-cli people
      minutes-cli person-meetings <person-id> [--json] [--data-dir <path>]
      minutes-cli voices samples <person-id> [--data-dir <path>]
      minutes-cli voices remember <person-id> <meeting-id> <cluster-id> --confirm [--data-dir <path>]
      minutes-cli folders list|seed|create|update|delete|move|meetings|classify [options] [--data-dir <path>]
      minutes-cli google auth|status|events|calendars|disconnect --config <public-client-metadata.json>
      minutes-cli prism status|verify|outbox|sync|disconnect --origin <https-origin>
      minutes-cli prism enqueue <meeting-id> --origin <https-origin> --vault <granted-vault-id>
      minutes-cli speech-regions <audio-path>
      minutes-cli audio-input
      minutes-cli capture-system --output-dir <new-directory> --seconds <duration> [--system-only] [--request-permission]
      minutes-cli models status|setup|prepare
      minutes-cli events [--today | --days 7] [--json] [--request-access]
      minutes-cli bind-event <meeting-id> <event-occurrence-id> [--today | --days 7]
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
    @MainActor
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
            if ["help", "--help", "-h"].contains(cmd) { printHelp(); return }
            if cmd == "find-transcript" {
                guard args.count >= 4 else { throw NSError(domain: "Minutes.Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use find-transcript <meeting-id> <query> [--data-dir <path>]."]) }
                let store = try getStore(dataDir: dataDir)
                guard store.getMeeting(id: args[2]) != nil else { throw NSError(domain: "Minutes.Search", code: 2, userInfo: [NSLocalizedDescriptionKey: "Meeting not found."]) }
                let matches = TranscriptSearch.matches(in: store.listUtterances(meetingId: args[2]), query: args[3])
                // Deliberate CLI output contains offsets only, never transcript text.
                print(String(decoding: try JSONEncoder().encode(matches), as: UTF8.self))
                return
            }
            if cmd == "speech-regions" {
                guard args.count == 3 else { throw ASRError.audioUnreadable("Use speech-regions <audio-path>.") }
                let audio = try AudioDecoder.decode(fileURL: URL(fileURLWithPath: args[2]))
                let result = try await DiarizationService().diarize(samples: audio.samples, sampleRate: audio.sampleRate, meetingId: "local-diagnostic")
                let output: [String: Any] = ["duration": audio.duration, "regions": result.segments.map { ["start": $0.start, "end": $0.end] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if cmd == "audio-input" {
                guard args.count == 2 else { throw NSError(domain: "Minutes.AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use audio-input without options."]) }
                if let input = CaptureInputDevices.current() {
                    print("Input: \(input.name); \(Int(input.sampleRate)) Hz; Bluetooth: \(input.isBluetooth)")
                } else { print("No current microphone input.") }
                return
            }
            if cmd == "capture-system" { try await SystemCaptureCLI.run(arguments: Array(args.dropFirst(2))); return }
            if cmd == "google" { try await GoogleCalendarCLI.run(arguments: args); return }
            if cmd == "models" {
                guard args.count >= 3, ["status", "setup", "prepare"].contains(args[2]) else {
                    print("Usage: minutes-cli models status|setup|prepare (setup explicitly downloads local speaker models)")
                    exit(1)
                }
                if args[2] == "setup" {
                    print("Downloading and verifying trained local diarization models...")
                    try await ModelManager.shared.setupDiarizationModels()
                }
                let readiness = ModelManager.shared.diarizationReadiness()
                if args[2] == "prepare" {
                    guard readiness.ready else { throw SpeechModelsError.missingDiarizationModels }
                    try await ASRService().prepareForRecording()
                    print("On-device speech recognition permission and availability verified.")
                }
                print(readiness.reason)
                return
            }
            if cmd == "events" || cmd == "bind-event" {
                let provider = EventKitCalendarProvider()
                if args.contains("--request-access") { try await provider.requestAccess() }
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: Date())
                var days = args.contains("--today") ? 1 : 7
                if let index = args.firstIndex(of: "--days"), index + 1 < args.count {
                    guard let value = Int(args[index + 1]), (1...31).contains(value) else { throw CalendarAccessError.invalidInterval }
                    days = value
                }
                let end = calendar.date(byAdding: .day, value: days, to: start)!
                let events = try provider.events(in: DateInterval(start: start, end: end))
                if cmd == "events" {
                    if args.contains("--json") {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        print(String(decoding: try encoder.encode(events), as: UTF8.self))
                    } else {
                        print("Apple Calendar accounts (including configured Google accounts); read-only")
                        for event in events {
                            print("\(event.start.formatted())  \(event.title)  [\(event.id)]")
                            for attendee in event.attendees {
                                print("  Invited: \(attendee.displayName) \(attendee.email ?? "") (\(attendee.responseStatus))")
                            }
                        }
                        if events.isEmpty { print("No timed meetings in the selected interval.") }
                    }
                    return
                }
                guard args.count >= 4, let event = events.first(where: { $0.id == args[3] }) else {
                    print("Usage: minutes-cli bind-event <meeting-id> <event-occurrence-id> [--today | --days 7]")
                    print("Choose an occurrence ID from minutes-cli events in the same interval.")
                    exit(1)
                }
                let store = try getStore(dataDir: dataDir)
                let bound = try CalendarMeetingBinder.bind(meetingId: args[2], event: event, store: store)
                print("Bound local meeting \(bound.id) to \(event.title). Invitees are calendar context, not confirmed speakers.")
                return
            }
            let store = try getStore(dataDir: dataDir)

            if cmd == "prism" { try await PrismConnectionCLI.run(arguments: args, store: store); return }
            if cmd == "voices" { try VoiceEnrollmentCLI.run(arguments: args, store: store); return }
            if cmd == "folders" { try await FolderCLI.run(arguments: args, store: store); return }
            switch cmd {
            case "import", "import-transcript":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli \(cmd) <file-path> [--title <title>] [--data-dir <path>]")
                    exit(1)
                }
                var title: String? = nil
                if let index = args.firstIndex(of: "--title"), index + 1 < args.count { title = args[index + 1] }
                let directory: URL
                if let dataDir { directory = URL(fileURLWithPath: dataDir).appendingPathComponent("audio", isDirectory: true) }
                else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes/audio", isDirectory: true) }
                let importer = AudioImportService(store: store, audioDirectory: directory)
                let source = URL(fileURLWithPath: args[2])
                let meeting = try cmd == "import-transcript" ? importer.importTranscript(from: source, title: title) : importer.importAudio(from: source, title: title)
                print("Imported meeting: \(meeting.id) (\(meeting.title))")
                if let path = meeting.audioPath { print("Validated audio saved at: \(path)") }
                else { print("Untimed transcript imported; speaker identities and audio timestamps are unknown.") }

            case "recover-audio":
                guard args.count >= 3, var meeting = store.getMeeting(id: args[2]),
                      meeting.status == "interrupted", let path = meeting.audioPath else {
                    print("Choose an interrupted meeting with saved microphone audio. Active captures are never repaired.")
                    exit(1)
                }
                let directory = dataDir.map { URL(fileURLWithPath: $0).appendingPathComponent("audio", isDirectory: true) } ??
                    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes/audio", isDirectory: true)
                let copy = try InterruptedWAVRecovery.makeCopy(original: URL(fileURLWithPath: path), meetingID: meeting.id, managedAudioDirectory: directory)
                meeting.audioPath = copy.path
                meeting.status = "recorded"
                try store.saveMeeting(meeting)
                print("Recovery copy saved for \(meeting.id). Original preserved; processing has not started.")

            case "process":
                if args.contains("--transcript") {
                    print("Plain text cannot provide verified audio timing. Use minutes-cli import-transcript <text-path> instead.")
                    exit(1)
                }
                guard args.count >= 3 else {
                    print("Usage: minutes-cli process <meeting-id> [--audio <path>] [--transcript <path>] [--data-dir <path>]")
                    exit(1)
                }
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting \(meetingId) not found.")
                    exit(1)
                }
                
                print("Processing meeting \(meetingId)...")
                
                // Locate audio file
                var audioURL: URL? = nil
                if let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) {
                    audioURL = URL(fileURLWithPath: path)
                } else if let aIdx = args.firstIndex(of: "--audio"), aIdx + 1 < args.count {
                    let aPath = args[aIdx + 1]
                    if FileManager.default.fileExists(atPath: aPath) {
                        audioURL = URL(fileURLWithPath: aPath)
                    }
                }
                
                guard let validAudioURL = audioURL else {
                    print("Error: No audio file found for meeting \(meetingId). Please re-import with valid audio.")
                    exit(1)
                }
                
                let orchestrator = PipelineOrchestrator()
                let result: PipelineResult
                do {
                    result = try await orchestrator.process(
                        meetingId: meetingId,
                        audioURL: validAudioURL
                    )
                } catch {
                    print("Error in speech processing pipeline: \(error.localizedDescription)")
                    var failedM = meeting
                    failedM.status = "failed"
                    try? store.saveMeeting(failedM)
                    exit(1)
                }
                
                let identified = RememberedSpeakerIdentification.apply(
                    clusters: result.clusters, utterances: result.utterances,
                    people: store.listPeople(), voiceprints: store.listVoiceprints(),
                    existingClusters: store.listSpeakerClusters(meetingId: meetingId),
                    attendeePersonIDs: Set(store.listPeopleForMeeting(meetingId: meetingId).map(\.id)))
                let finalUtterances = identified.utterances

                var updatedM = meeting
                updatedM.status = "needs_review"
                try store.withTransaction {
                    try store.saveSpeakerClusters(identified.clusters)
                    try store.saveUtterances(finalUtterances)
                    try store.saveMeeting(updatedM)
                }
                
                print("✅ Processed meeting \(meetingId):")
                print("   Audio duration: \(String(format: "%.1f", result.audioDuration))s")
                print("   Speech duration: \(String(format: "%.1f", result.speechDuration))s")
                print("   Words: \(result.words.count)")
                print("   Utterances: \(finalUtterances.count)")
                print("   Acoustic clusters: \(result.clusters.count)")
                for c in identified.clusters {
                    let assigned = c.label
                    print("     - \(c.label): \(assigned) (\(String(format: "%.1f", c.speechSeconds))s speech)")
                }
                
            case "assign":
                guard args.count >= 4 else {
                    print("Usage: minutes-cli assign <meeting-id> <cluster-label>=<name-or-email> [--learn]")
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
                
                let shouldLearn = args.contains("--learn")
                if shouldLearn && (cluster.embeddingModel != SpeakerEmbeddingModel.trainedID || cluster.centroid.count != 256 || !cluster.centroid.allSatisfy(\.isFinite)) {
                    print("Cannot learn from this cluster: reprocess with the trained embedding model first. Assignment without --learn remains available.")
                    exit(1)
                }
                // Resolve name / person
                let displayName = targetIdentity.contains("@") ? NameResolver.resolveDisplayName(fromEmail: targetIdentity) : targetIdentity
                let email = targetIdentity.contains("@") ? NameResolver.cleanEmail(targetIdentity) : ""
                
                // Find or create Person
                let people = store.listPeople()
                var person = people.first(where: { p in
                    email.isEmpty ? p.displayName.lowercased() == displayName.lowercased() : p.emails.contains { NameResolver.cleanEmail($0) == email }
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
                
                // Voice enrollment requires explicit consent and trained model provenance.
                if shouldLearn && !cluster.centroid.isEmpty {
                    let vp = Voiceprint(
                        personId: assignedPerson.id,
                        model: SpeakerEmbeddingModel.trainedID,
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
                
            case "suggest-title":
                guard args.count >= 3, store.getMeeting(id: args[2]) != nil else {
                    print("Usage: minutes-cli suggest-title <meeting-id> [--data-dir <path>]")
                    exit(1)
                }
                if let title = MeetingTitleGenerator.suggest(from: store.listUtterances(meetingId: args[2])) {
                    print(title)
                } else { print("Insufficient transcript evidence for a useful title.") }

            case "summarize":
                guard args.count >= 3, !args[2].hasPrefix("--") else {
                    print("Usage: minutes-cli summarize <meeting-id> [--engine apple|extractive] [--template general|oneToOne|standup|interview]")
                    exit(1)
                }
                let options = try SummaryCommandOptions(arguments: Array(args.dropFirst(3)))
                let meetingId = args[2]
                guard let meeting = store.getMeeting(id: meetingId) else {
                    print("Meeting \(meetingId) not found.")
                    exit(1)
                }
                let utterances = store.listUtterances(meetingId: meetingId)
                let people = store.listPeopleForMeeting(meetingId: meetingId)
                let provider: (any LLMProvider)?
                if options.engine == .apple {
                    let availability = FoundationModelsProvider.availability()
                    guard availability == .available else { throw LocalSummaryProviderError.unavailable(availability) }
                    provider = FoundationModelsProvider()
                } else { provider = nil }
                let summary = try await Summarizer(provider: provider).summarize(meeting: meeting,
                    utterances: utterances, attendees: people, template: options.template)
                var updatedMeeting = meeting
                updatedMeeting.status = "summarized"
                try store.withTransaction {
                    try store.saveSummary(summary)
                    try store.saveMeeting(updatedMeeting)
                }
                if options.engine == .apple {
                    print("Apple on-device draft saved for \(meetingId), template \(options.template.title). Review generated notes against their cited evidence.")
                } else {
                    print("Extractive notes saved for \(meetingId). Review quoted candidates; templates apply to generated notes.")
                }

            case "export":
                guard args.count >= 3 else {
                    print("Usage: minutes-cli export <meeting-id> [--target parachute|markdown] [--output-dir <directory>]")
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
                if let tIdx = args.firstIndex(of: "--target") {
                    guard tIdx + 1 < args.count else { print("--target requires markdown or parachute"); exit(1) }
                    target = args[tIdx + 1]
                }
                guard ["markdown", "parachute"].contains(target) else {
                    print("Unknown export destination: \(target)")
                    exit(1)
                }
                if target == "markdown" {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    var mdDir = (home as NSString).appendingPathComponent("Documents/Minutes")
                    if let index = args.firstIndex(of: "--output-dir") {
                        guard index + 1 < args.count else { print("--output-dir requires a path"); exit(1) }
                        mdDir = args[index + 1]
                    }
                    let adapter = MarkdownAdapter(outputDirectory: mdDir)
                    let res = try await adapter.export(bundle: bundle)
                    guard res.success else { print("Markdown export failed: \(res.error ?? "No receipt")"); exit(1) }
                    print("Exported to Markdown: \(res.pathOrURL ?? "")")
                } else {
                    let adapter = ParachuteAdapter()
                    let res = try await adapter.export(bundle: bundle)
                    if res.success {
                        print("Exported through legacy macOS Parachute CLI adapter:")
                        print("   Note ID: \(res.externalRef ?? "")")
                        print("   URL: \(res.pathOrURL ?? "")")
                    } else {
                        print("Legacy Parachute export failed: \(res.error ?? "unknown")")
                        exit(1)
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
                
            case "person-meetings":
                guard args.count >= 3, !args[2].hasPrefix("--") else {
                    print("Usage: minutes-cli person-meetings <person-id> [--json] [--data-dir <path>]")
                    exit(1)
                }
                guard store.getPerson(id: args[2]) != nil else {
                    throw NSError(domain: "MinutesCLI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No local person exists with that ID."])
                }
                let history = try store.listMeetings(forPersonId: args[2])
                if args.contains("--json") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    print(String(decoding: try encoder.encode(history), as: UTF8.self))
                } else {
                    if history.isEmpty { print("No linked local meetings for this person.") }
                    for entry in history {
                        var context: [String] = []
                        if entry.calendarInvitee { context.append("Calendar invitee") }
                        if entry.confirmedSpeaker { context.append("Confirmed speaker") }
                        if entry.recognizedSpeaker { context.append("Recognized voice") }
                        if entry.speakerLinked && !entry.confirmedSpeaker && !entry.recognizedSpeaker { context.append("Speaker link needs review") }
                        print("\(entry.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))  \(entry.meeting.title) [\(entry.id)] — \(context.joined(separator: ", "))")
                    }
                    print("Calendar invitation does not establish that someone spoke. Up to 100 latest local meetings are shown.")
                }

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
