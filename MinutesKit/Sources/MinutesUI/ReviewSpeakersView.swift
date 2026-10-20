#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeakerID
import MinutesSpeech
import MinutesCalendar

/// Presentation rules shared by speaker review and the remembered-voice library.
enum SpeakerReviewPresentation {
    static func personForConfirmation(name: String, email: String, knownPeople: [Person]) -> Person {
        let cleanedEmail = NameResolver.cleanEmail(email)
        if !cleanedEmail.isEmpty,
           let existing = knownPeople.first(where: { person in
               person.emails.contains { NameResolver.cleanEmail($0) == cleanedEmail }
           }) {
            return existing
        }
        return Person(displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                      emails: cleanedEmail.isEmpty ? [] : [cleanedEmail])
    }

    static func speechDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Unknown duration" }
        if seconds > 0 && seconds < 1 { return "Less than 1 sec" }
        let total = Int(seconds)
        let minutes = total / 60, remainder = total % 60
        if minutes == 0 { return "\(remainder) sec" }
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }

    static func canRemember(_ cluster: SpeakerCluster) -> Bool {
        VoiceEnrollment.isEligible(cluster)
    }

    static func profileWarning(_ profile: Voiceprint) -> String? {
        guard profile.model == SpeakerEmbeddingModel.trainedID else {
            return "Older voice profile — record and confirm a new sample with at least 20 seconds of usable speech."
        }
        guard profile.dim == 256, profile.vector.count == 256, profile.vector.allSatisfy(\.isFinite), VectorMath.l2Norm(profile.vector) > 1e-12 else {
            return "This voice sample cannot be used for recognition. Record and confirm a new sample."
        }
        guard profile.speechSeconds.isFinite, profile.speechSeconds >= 20 else {
            return "Short sample: not eligible for automatic recognition. Confirm at least 20 seconds of usable speech in a meeting to improve this voice."
        }
        return nil
    }

    static func rememberExplanation(_ cluster: SpeakerCluster) -> String {
        if canRemember(cluster) { return "Optional. Use this confirmed voice to suggest a name in future meetings." }
        if cluster.speechSeconds.isFinite && cluster.speechSeconds >= 0 && cluster.speechSeconds < 20 {
            return "Remembering a voice needs at least 20 seconds of usable speech from this speaker. This sample has \(speechDuration(cluster.speechSeconds)). You can still confirm their name."
        }
        return "No usable voice sample is available for recognition. You can still confirm their name."
    }
}

@available(macOS 15.0, iOS 18.0, *)
public struct ReviewSpeakersView: View {
    public let meeting: Meeting
    @State public var clusters: [SpeakerCluster]
    @State public var attendees: [Person]
    public let utterances: [Utterance]
    public let voiceprints: [Voiceprint]
    public let playbackAllowed: Bool
    
    // Learning checkbox
    @State private var learnFromConfirmedVoice: Bool = false
    
    // Active Candidate Cluster being reviewed
    @State private var activeClusterIndex: Int = 0
    @State private var isCreatingPerson: Bool = false
    @State private var newPersonName: String = ""
    @State private var newPersonEmail: String = ""
    @State private var choosingPerson = false
    @State private var personSearch = ""
    @State private var addedPeople: [Person] = []
    
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showingSpeakerDetail = false
    @State private var playbackError: String?
    @State private var assignmentFeedback: String?

    // Audio Playback
    @ObservedObject private var playback = AudioPlaybackService.shared
    
    public let onAssign: (String, Person) -> Void
    public let onLockAndEnroll: ([SpeakerCluster]) -> Void
    public let onReassignUtterances: (String, String) -> Void // clusterId, newName
    public let onKeepUnknown: (String) -> Void
    public let availablePeople: [Person]
    
    private let incomingClusters: [SpeakerCluster]
    private let incomingAttendees: [Person]
    
    public init(
        meeting: Meeting,
        clusters: [SpeakerCluster],
        attendees: [Person],
        utterances: [Utterance] = [],
        voiceprints: [Voiceprint] = [],
        onAssign: @escaping (String, Person) -> Void,
        onLockAndEnroll: @escaping ([SpeakerCluster]) -> Void,
        onReassignUtterances: @escaping (String, String) -> Void = { _, _ in },
        onKeepUnknown: @escaping (String) -> Void = { _ in },
        availablePeople: [Person] = [],
        playbackAllowed: Bool = true
    ) {
        self.meeting = meeting
        self._clusters = State(initialValue: clusters)
        self.incomingClusters = clusters
        self.incomingAttendees = attendees
        self._attendees = State(initialValue: attendees)
        self.utterances = utterances
        self.voiceprints = voiceprints
        self.onAssign = onAssign
        self.onLockAndEnroll = onLockAndEnroll
        self.onReassignUtterances = onReassignUtterances
        self.onKeepUnknown = onKeepUnknown
        self.availablePeople = availablePeople
        self.playbackAllowed = playbackAllowed
    }
    
    private var incomingRevision: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(ReviewInput(clusters: incomingClusters, people: incomingAttendees))
    }

    private struct ReviewInput: Encodable {
        let clusters: [SpeakerCluster]
        let people: [Person]
    }

    private var activeCluster: SpeakerCluster? {
        guard !clusters.isEmpty else { return nil }
        if activeClusterIndex < clusters.count {
            return clusters[activeClusterIndex]
        }
        return clusters.first
    }
    
    private var activeClusterUtterances: [Utterance] {
        guard let cluster = activeCluster else { return [] }
        return utterances.filter { $0.clusterId == cluster.id }
    }
    
    private var activeSampleUtterance: Utterance? {
        guard let cluster = activeCluster,
              let sample = SpeakerAudioSample(utterances: activeClusterUtterances, clusterID: cluster.id) else { return nil }
        return activeClusterUtterances.first { $0.start == sample.start && $0.end >= sample.end }
    }

    public var body: some View {
        Group {
            if usesCompactLayout {
                if showingSpeakerDetail {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                playback.pause()
                                showingSpeakerDetail = false
                            } label: {
                                Label("Speakers", systemImage: "chevron.backward")
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .minutesControlGlass(in: Capsule(), interactive: true)
                            }.buttonStyle(.plain)
                            Spacer()
                            Text("\(activeClusterIndex + 1) of \(clusters.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                        speakerDetail
                    }
                } else if clusters.isEmpty {
                    speakerDetail
                } else {
                    speakerList
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    speakerList
                    Divider()
                    speakerDetail
                }
            }
        }
        .background(MinutesTheme.document)
        .onChange(of: incomingRevision) { _, _ in
            clusters = incomingClusters
            attendees = incomingAttendees
            activeClusterIndex = min(activeClusterIndex, max(0, clusters.count - 1))
        }
        .onChange(of: activeClusterIndex) { _, _ in
            learnFromConfirmedVoice = false
            playback.pause()
        }
        .alert("Couldn’t play sample", isPresented: Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )) {
            Button("OK") { playbackError = nil }
        } message: {
            Text(playbackError ?? "")
        }
        .sheet(isPresented: $isCreatingPerson) {
            VStack(spacing: 16) {
                Text("Name this speaker")
                    .font(.headline)
                TextField("Name", text: $newPersonName)
                    .textFieldStyle(.roundedBorder)
                TextField("Email (optional)", text: $newPersonEmail)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { isCreatingPerson = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                    Button("Add and confirm") {
                        if !newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let cluster = activeCluster {
                            let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let email = newPersonEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                            let knownPeople = attendees + availablePeople + addedPeople
                            let p = SpeakerReviewPresentation.personForConfirmation(name: name, email: email, knownPeople: knownPeople)
                            if !knownPeople.contains(where: { $0.id == p.id }) { addedPeople.append(p) }
                            confirmCluster(cluster, asPerson: p)
                            isCreatingPerson = false
                            newPersonName = ""
                            newPersonEmail = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(minWidth: 300, idealWidth: 360)
        }
    }
    
    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var speakerDetail: some View {
        ScrollView {
            if let cluster = activeCluster {
                VStack(alignment: .leading, spacing: 24) {
                    speakerHeader(cluster)
                    sampleSection
                    Divider()
                    identitySection(cluster)
                    rememberSection(cluster)
                    if let assignmentFeedback {
                        Label(assignmentFeedback, systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if !activeClusterUtterances.isEmpty {
                        Divider()
                        conversationSection
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(usesCompactLayout ? 20 : 24)
            } else {
                ContentUnavailableView {
                    Label("No speakers to review", systemImage: "person.wave.2")
                } description: {
                    Text("Speakers appear here after a recording is transcribed.")
                }.padding(.vertical, 40)
            }
        }
    }

    private var speakerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speakers").font(.headline)
                Text("\(clusters.filter { $0.assignment == "user" }.count) of \(clusters.count) confirmed")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.top, 16)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(clusters.indices, id: \.self) { index in
                        let cluster = clusters[index]
                        Button { activeClusterIndex = index; showingSpeakerDetail = true; assignmentFeedback = nil } label: {
                            HStack(spacing: 12) {
                              VStack(alignment: .leading, spacing: 5) {
                                Text(speakerName(cluster)).font(.callout.weight(.medium)).lineLimit(2)
                                Label(reviewStatus(cluster), systemImage: reviewSymbol(cluster))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(formatSpeechSeconds(cluster.speechSeconds))
                                    .font(.caption).foregroundStyle(.secondary)
                              }.frame(maxWidth: .infinity, alignment: .leading)
                              if usesCompactLayout {
                                  Image(systemName: "chevron.forward").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                              }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(!usesCompactLayout && activeClusterIndex == index ? Color.accentColor.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(activeClusterIndex == index ? .isSelected : [])
                    }
                }.padding(.horizontal, 6)
            }
        }.frame(minWidth: usesCompactLayout ? 0 : 145,
                idealWidth: usesCompactLayout ? nil : 170,
                maxWidth: usesCompactLayout ? .infinity : 190)
    }

    private func speakerName(_ cluster: SpeakerCluster) -> String {
        let name = cluster.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == cluster.id {
            return "Speaker \((clusters.firstIndex(where: { $0.id == cluster.id }) ?? 0) + 1)"
        }
        return name
    }

    private func reviewStatus(_ cluster: SpeakerCluster) -> String {
        switch cluster.assignment {
        case "user": return "Confirmed"
        case "unknown": return "Kept unknown"
        case "auto": return "Remembered match · unconfirmed"
        case "me_channel": return "Microphone source"
        default: return cluster.personId == nil ? "Needs a name" : "Name suggested"
        }
    }

    private func reviewSymbol(_ cluster: SpeakerCluster) -> String {
        switch cluster.assignment {
        case "user": return "checkmark.circle"
        case "auto": return "waveform"
        case "me_channel": return "mic"
        default: return "person.crop.circle.badge.questionmark"
        }
    }

    private func speakerHeader(_ cluster: SpeakerCluster) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(speakerName(cluster)).font(.title2.weight(.semibold))
                Label(reviewStatus(cluster), systemImage: reviewSymbol(cluster))
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(formatSpeechSeconds(cluster.speechSeconds)) of usable speech")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sample = activeSampleUtterance {
                if let cluster = activeCluster {
                    VoiceSamplePlaybackView(meeting: meeting, cluster: cluster,
                        utterances: activeClusterUtterances, playbackAllowed: playbackAllowed)
                        .id(cluster.id)
                }
                Text(sample.text).font(.body).lineSpacing(5).textSelection(.enabled)
            } else {
                Text("No speech sample is available. You can still choose a name.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func identitySection(_ cluster: SpeakerCluster) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is speaking?").font(.headline)
            Text(cluster.assignment == "auto" ? "Matched to a remembered voice. Listen before confirming." :
                 cluster.personId != nil && cluster.assignment != "user" ? "This name is a suggestion. Listen before confirming." :
                 "Choose a person to update their name throughout this transcript.")
                .font(.callout).foregroundStyle(.secondary)
            if !attendees.isEmpty {
                Text("Calendar invitees may be absent. An RSVP does not confirm attendance or identify a voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { personChooser(cluster); confirmSuggestedPerson(cluster) }
                VStack(alignment: .leading, spacing: 10) { personChooser(cluster); confirmSuggestedPerson(cluster) }
            }
            Button("Keep unknown") { markClusterUnknown(cluster) }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                .disabled(cluster.assignment == "unknown")
        }
    }

    private func personChooser(_ cluster: SpeakerCluster) -> some View {
        Button { personSearch = ""; choosingPerson = true } label: {
            Label(cluster.assignment == "user" ? "Change person" : "Choose a person", systemImage: "person.crop.circle")
                .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: usesCompactLayout ? 44 : 34)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }.buttonStyle(.plain).fixedSize()
            .popover(isPresented: $choosingPerson, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a person", text: $personSearch).textFieldStyle(.plain)
                            .accessibilityLabel("Find a person by name or email")
                        if !personSearch.isEmpty {
                            Button { personSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear person search")
                        }
                    }.padding(14)
                    Divider()
                    List {
                        Section("Calendar invitees") {
                            if filteredPeople.filter({ person in attendees.contains { $0.id == person.id } }).isEmpty {
                                Text("No matching invitees").foregroundStyle(.secondary)
                            }
                            ForEach(filteredPeople.filter { person in attendees.contains { $0.id == person.id } }) { person in
                                personRow(person, cluster: cluster)
                            }
                        }
                        Section("Other people") {
                            ForEach(filteredPeople.filter { person in !attendees.contains { $0.id == person.id } }) { person in
                                personRow(person, cluster: cluster)
                            }
                        }
                    }.listStyle(.plain)
                        .overlay {
                            if filteredPeople.isEmpty {
                                Text(personSearch.isEmpty ? "No saved people yet." : "No matching people.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    Divider()
                    Button {
                        choosingPerson = false
                        newPersonName = personSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                        isCreatingPerson = true
                    } label: {
                        Label("Add person not on the invitation…", systemImage: "person.badge.plus")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.buttonStyle(.plain)
                }.frame(idealWidth: 320, maxWidth: 360, minHeight: 360)
                    .background(MinutesTheme.document)
                    .presentationDetents([.medium, .large])
            }
    }

    private func personRow(_ person: Person, cluster: SpeakerCluster) -> some View {
                            Button {
                                choosingPerson = false
                                confirmCluster(cluster, asPerson: person)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(person.displayName).font(.callout.weight(.medium))
                                        if let email = person.emails.first {
                                            Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if attendees.contains(where: { $0.id == person.id }) {
                                            Text("Calendar invitee").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if cluster.personId == person.id {
                                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
    }

    private var filteredPeople: [Person] {
        var seen = Set<String>()
        let sortedAttendees = attendees.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let sortedPeople = (availablePeople + addedPeople).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let people = (sortedAttendees + sortedPeople).filter { seen.insert($0.id).inserted }
        let query = personSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return people }
        return people.filter { person in
            person.displayName.localizedCaseInsensitiveContains(query) ||
            person.emails.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder private func confirmSuggestedPerson(_ cluster: SpeakerCluster) -> some View {
        if cluster.assignment != "user",
           suggestedPerson(for: cluster) != nil {
            Button { confirmActiveCluster() } label: {
                Label("Confirm \(speakerName(cluster))", systemImage: "checkmark")
                    .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: usesCompactLayout ? 44 : 34)
                    .minutesControlGlass(in: Capsule(), interactive: true)
            }.buttonStyle(.plain)
        }
    }

    private func rememberSection(_ cluster: SpeakerCluster) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remember this voice on this device", isOn: $learnFromConfirmedVoice)
                .font(.callout).disabled(!canRemember(cluster))
            Text(SpeakerReviewPresentation.rememberExplanation(cluster))
                .font(.caption).foregroundStyle(.secondary)
            if learnFromConfirmedVoice {
                Text("Saved only when you confirm a person above.")
                    .font(.caption).foregroundStyle(.secondary)
                if cluster.assignment == "user" {
                    Button { confirmActiveCluster() } label: {
                        Label("Confirm and remember voice", systemImage: "waveform")
                            .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: usesCompactLayout ? 44 : 34)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain)
                }
            }
            if voiceprints.isEmpty {
                Text("No remembered voices yet. Choose this option before confirming to recognize this person in future meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if voiceprints.allSatisfy({ SpeakerReviewPresentation.profileWarning($0) != nil }) {
                Text("No saved voices are ready for recognition. Older or short samples need a new confirmed sample with at least 20 seconds of speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var conversationSection: some View {
        DisclosureGroup("More from this speaker (\(activeClusterUtterances.count))") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(activeClusterUtterances.prefix(8)) { utterance in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { toggleSamplePlayback(sample: utterance) } label: {
                            Label(formatTime(utterance.start), systemImage: isPlayingThisSample(utterance) ? "pause.circle" : "play.circle")
                                .font(.caption.monospacedDigit())
                        }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!hasTimedAudio || !playbackAllowed)
                        Text(utterance.text).font(.callout).lineSpacing(4).textSelection(.enabled)
                    }
                }
            }.padding(.top, 12)
        }.font(.callout.weight(.medium))
    }

    private var hasTimedAudio: Bool { meeting.audioPath != nil && meeting.platform != "transcript_import" }

    // MARK: - Actions
    
    private func canRemember(_ cluster: SpeakerCluster) -> Bool {
        SpeakerReviewPresentation.canRemember(cluster)
    }

    private func confirmActiveCluster() {
        guard let cluster = activeCluster else { return }
        guard let existingPerson = suggestedPerson(for: cluster) else { return }
        confirmCluster(cluster, asPerson: existingPerson)
    }

    private func suggestedPerson(for cluster: SpeakerCluster) -> Person? {
        if let personID = cluster.personId {
            return (attendees + availablePeople + addedPeople).first(where: { $0.id == personID })
        }
        return (attendees + availablePeople + addedPeople).first(where: { $0.displayName == cluster.label })
    }
    
    private func confirmCluster(_ cluster: SpeakerCluster, asPerson person: Person) {
        guard let idx = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[idx].label = person.displayName
        clusters[idx].personId = person.id
        clusters[idx].assignment = "user"
        clusters[idx].confidence = 1.0
        
        onAssign(cluster.id, person)
        onReassignUtterances(cluster.id, person.displayName)
        
        if learnFromConfirmedVoice && canRemember(cluster) {
            onLockAndEnroll([clusters[idx]])
        }
        
        assignmentFeedback = "Confirmed as \(person.displayName)"
        learnFromConfirmedVoice = false

        // Advance to next unconfirmed cluster
        if let nextIdx = clusters.firstIndex(where: { $0.assignment != "user" && $0.assignment != "unknown" }) {
            activeClusterIndex = nextIdx
        }
    }
    
    private func markClusterUnknown(_ cluster: SpeakerCluster) {
        guard let idx = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[idx].label = "Unknown speaker"
        clusters[idx].personId = nil
        clusters[idx].assignment = "unknown"
        clusters[idx].confidence = 0
        onKeepUnknown(cluster.id)
        onReassignUtterances(cluster.id, "Unknown speaker")
        learnFromConfirmedVoice = false
        assignmentFeedback = "Kept unknown"
    }
    
    private func toggleSamplePlayback(sample: Utterance) {
        guard hasTimedAudio && playbackAllowed else { return }
        if isPlayingThisSample(sample) {
            playback.pause()
        } else if let cluster = activeCluster {
            do {
                let path = try SpeakerAudioSample.audioPath(meeting: meeting, cluster: cluster)
                try playback.loadAudio(path: path)
                if !playback.play(from: sample.start, to: min(sample.end, sample.start + 12)) {
                    playbackError = "Audio playback could not start. Check the audio output and try again."
                }
            } catch {
                playbackError = error.localizedDescription
            }
        }
    }
    
    private func isPlayingThisSample(_ sample: Utterance) -> Bool {
        let path = activeCluster.flatMap { try? SpeakerAudioSample.audioPath(meeting: meeting, cluster: $0) }
        return playback.currentAudioPath == path && playback.isPlaying && playback.currentTime >= sample.start && playback.currentTime <= sample.end
    }
    
    private func formatSpeechSeconds(_ sec: Double) -> String {
        SpeakerReviewPresentation.speechDuration(sec)
    }
    
    private func formatDuration(_ sec: Double) -> String {
        SpeakerReviewPresentation.speechDuration(sec)
    }
    
    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
    
    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
}
#endif
