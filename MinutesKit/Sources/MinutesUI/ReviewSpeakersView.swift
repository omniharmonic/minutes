#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeakerID
import MinutesSpeech

@available(macOS 15.0, iOS 18.0, *)
public struct ReviewSpeakersView: View {
    public let meeting: Meeting
    @State public var clusters: [SpeakerCluster]
    @State public var attendees: [Person]
    public let utterances: [Utterance]
    @State public var voiceprints: [Voiceprint]
    
    // Learning checkbox
    @State private var learnFromConfirmedVoice: Bool = true
    
    // Active Candidate Cluster being reviewed
    @State private var activeClusterIndex: Int = 0
    @State private var selectedPersonName: String = ""
    @State private var isCreatingPerson: Bool = false
    @State private var newPersonName: String = ""
    @State private var newPersonEmail: String = ""
    
    // Audio Playback
    @ObservedObject private var playback = AudioPlaybackService.shared
    
    public let onAssign: (String, Person) -> Void
    public let onLockAndEnroll: ([SpeakerCluster]) -> Void
    public let onReassignUtterances: (String, String) -> Void // clusterId, newName
    
    private let matcher = SpeakerMatcher()
    
    public init(
        meeting: Meeting,
        clusters: [SpeakerCluster],
        attendees: [Person],
        utterances: [Utterance] = [],
        voiceprints: [Voiceprint] = [],
        onAssign: @escaping (String, Person) -> Void,
        onLockAndEnroll: @escaping ([SpeakerCluster]) -> Void,
        onReassignUtterances: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.meeting = meeting
        self._clusters = State(initialValue: clusters)
        self._attendees = State(initialValue: attendees)
        self.utterances = utterances
        self._voiceprints = State(initialValue: voiceprints)
        self.onAssign = onAssign
        self.onLockAndEnroll = onLockAndEnroll
        self.onReassignUtterances = onReassignUtterances
    }
    
    private var unconfirmedClusters: [SpeakerCluster] {
        clusters.filter { $0.assignment != "user" }
    }
    
    private var confirmedClusters: [SpeakerCluster] {
        clusters.filter { $0.assignment == "user" }
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
        // Pick first clean utterance between 2 and 12 seconds if available
        let list = activeClusterUtterances
        if let ideal = list.first(where: { ($0.end - $0.start) >= 2.0 && ($0.end - $0.start) <= 12.0 }) {
            return ideal
        }
        return list.first
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header (matches mockups/review.png)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meetings / \(formatDate(meeting.startedAt))")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                        Text(meeting.title)
                            .font(.title2.bold())
                            .foregroundStyle(MinutesTheme.text)
                        Text("\(formatDuration(totalSpeechDuration)) · \(clusters.count) voices · Recorded on \(meeting.device ?? "Mac")")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    Spacer()
                    
                    HStack(spacing: 8) {
                        if !unconfirmedClusters.isEmpty {
                            Text("\(unconfirmedClusters.count) to confirm")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(Color.orange)
                                .clipShape(Capsule())
                        } else {
                            Text("All Confirmed")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(MinutesTheme.emerald.opacity(0.15))
                                .foregroundStyle(MinutesTheme.emerald)
                                .clipShape(Capsule())
                        }
                    }
                }
                
                // Two-Column Layout (matches mockups/review.png)
                HStack(alignment: .top, spacing: 24) {
                    // Left Column: Speaker Review Card & Confirmed Speakers
                    VStack(alignment: .leading, spacing: 18) {
                        if let cluster = activeCluster {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Does this sound like \(cluster.label)?")
                                    .font(.title3.bold())
                                    .foregroundStyle(MinutesTheme.text)
                                Text("A voice identified by acoustic embedding and calendar attendee mapping.")
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.muted)
                                
                                // Speaker Card
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack {
                                        // Initials Avatar
                                        Circle()
                                            .fill(avatarColorFor(cluster.label))
                                            .frame(width: 36, height: 36)
                                            .overlay(
                                                Text(initialsFor(cluster.label))
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(.white)
                                            )
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(cluster.label + (cluster.assignment == "user" ? "" : "?"))
                                                .font(.headline)
                                                .foregroundStyle(MinutesTheme.text)
                                            Text("\(formatSpeechSeconds(cluster.speechSeconds)) of speech · \(cluster.centroid.count)-dim acoustic vector")
                                                .font(.caption2)
                                                .foregroundStyle(MinutesTheme.muted)
                                        }
                                        
                                        Spacer()
                                        
                                        // Status Pill
                                        statusPill(cluster.assignment)
                                    }
                                    
                                    // Audio Waveform & Listen Button
                                    VStack(alignment: .leading, spacing: 8) {
                                        waveformBars
                                        
                                        if let sample = activeSampleUtterance {
                                            HStack {
                                                Button(action: {
                                                    toggleSamplePlayback(sample: sample)
                                                }) {
                                                    HStack(spacing: 6) {
                                                        Image(systemName: isPlayingThisSample(sample) ? "pause.fill" : "play.fill")
                                                        Text(isPlayingThisSample(sample) ? "Pause sample" : "▶ Listen to \(Int(sample.end - sample.start))-second sample")
                                                    }
                                                    .font(.caption.bold())
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                }
                                                .buttonStyle(.bordered)
                                                
                                                Spacer()
                                                
                                                Text("\(formatTime(sample.start))–\(formatTime(sample.end))")
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(MinutesTheme.muted)
                                            }
                                            
                                            // Quote from speech
                                            Text("“\(sample.text)”")
                                                .font(.subheadline)
                                                .italic()
                                                .foregroundStyle(MinutesTheme.muted)
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(MinutesTheme.cardHover)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(MinutesTheme.border, lineWidth: 1)
                                                )
                                        } else {
                                            Text("No speech sample recorded for this cluster.")
                                                .font(.caption)
                                                .foregroundStyle(MinutesTheme.muted)
                                        }
                                    }
                                    
                                    // Assignment & Confirm Controls
                                    HStack(spacing: 10) {
                                        Menu {
                                            ForEach(attendees) { p in
                                                Button(p.displayName) {
                                                    confirmCluster(cluster, asPerson: p)
                                                }
                                            }
                                            Button("Add Someone Else...") {
                                                isCreatingPerson = true
                                            }
                                            Button("Keep Unknown") {
                                                markClusterUnknown(cluster)
                                            }
                                        } label: {
                                            HStack {
                                                Text(cluster.personId != nil ? cluster.label : "Assign speaker...")
                                                    .font(.subheadline.weight(.medium))
                                                Image(systemName: "chevron.up.chevron.down")
                                                    .font(.caption2)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(MinutesTheme.cardHover)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(MinutesTheme.border, lineWidth: 1))
                                        }
                                        
                                        Button(action: {
                                            confirmActiveCluster()
                                        }) {
                                            Text(cluster.assignment == "user" ? "Confirmed ✓" : "Confirm speaker")
                                                .font(.subheadline.bold())
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(MinutesTheme.primary)
                                        .disabled(cluster.assignment == "user")
                                    }
                                    
                                    // Learning Checkbox
                                    Toggle(isOn: $learnFromConfirmedVoice) {
                                        Text("Learn from this confirmed voice on this device")
                                            .font(.caption)
                                            .foregroundStyle(MinutesTheme.muted)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                                .padding(18)
                                .minutesCard()
                            }
                        }
                        
                        // Confirmed Voices Strip
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CONFIRMED VOICES IN THIS MEETING")
                                .font(.caption.bold())
                                .foregroundStyle(MinutesTheme.muted)
                            
                            ForEach(clusters.indices, id: \.self) { idx in
                                let c = clusters[idx]
                                HStack {
                                    Circle()
                                        .fill(avatarColorFor(c.label))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Text(initialsFor(c.label))
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.label)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(MinutesTheme.text)
                                        Text(c.assignment == "user" ? "Confirmed by you" : "Suggested")
                                            .font(.caption2)
                                            .foregroundStyle(MinutesTheme.muted)
                                    }
                                    
                                    Spacer()
                                    
                                    if c.assignment == "user" {
                                        Button("Review / Edit") {
                                            activeClusterIndex = idx
                                        }
                                        .font(.caption)
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(MinutesTheme.primary)
                                    } else {
                                        Button("Review") {
                                            activeClusterIndex = idx
                                        }
                                        .font(.caption.bold())
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(10)
                                .background(activeClusterIndex == idx ? MinutesTheme.cardHover : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(16)
                        .minutesCard()
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Right Column: In The Conversation Excerpt (matches mockups/review.png)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("In the conversation")
                            .font(.title3.bold())
                            .foregroundStyle(MinutesTheme.text)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            if utterances.isEmpty {
                                Text("No utterances recorded.")
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.muted)
                                    .padding()
                            } else {
                                ForEach(utterances.prefix(8)) { u in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(u.speakerName)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(u.clusterId == activeCluster?.id ? MinutesTheme.primary : MinutesTheme.text)
                                            Spacer()
                                            Button(action: {
                                                playback.seek(to: u.start)
                                                playback.play(from: u.start, to: u.end)
                                            }) {
                                                Text(formatTime(u.start))
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(MinutesTheme.muted)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        
                                        Text(u.text)
                                            .font(.subheadline)
                                            .foregroundStyle(MinutesTheme.text.opacity(0.85))
                                            .lineSpacing(2)
                                    }
                                    .padding(.vertical, 6)
                                    .overlay(
                                        Rectangle()
                                            .frame(height: 1)
                                            .foregroundStyle(MinutesTheme.border.opacity(0.5)),
                                        alignment: .bottom
                                    )
                                }
                            }
                            
                            Text("A correction updates this meeting. Learning only uses speech you confirm.")
                                .font(.caption2)
                                .foregroundStyle(MinutesTheme.muted)
                                .padding(.top, 8)
                        }
                        .padding(18)
                        .minutesCard()
                    }
                    .frame(width: 380)
                }
            }
            .padding(20)
        }
        .background(MinutesTheme.bg)
        .sheet(isPresented: $isCreatingPerson) {
            VStack(spacing: 16) {
                Text("Add New Person")
                    .font(.headline)
                TextField("Full Name", text: $newPersonName)
                    .textFieldStyle(.roundedBorder)
                TextField("Email Address", text: $newPersonEmail)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { isCreatingPerson = false }
                        .buttonStyle(.bordered)
                    Button("Add & Assign") {
                        if !newPersonName.isEmpty, let cluster = activeCluster {
                            let p = Person(displayName: newPersonName, emails: newPersonEmail.isEmpty ? [] : [newPersonEmail])
                            attendees.append(p)
                            confirmCluster(cluster, asPerson: p)
                            isCreatingPerson = false
                            newPersonName = ""
                            newPersonEmail = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 320)
        }
    }
    
    // MARK: - Actions
    
    private func confirmActiveCluster() {
        guard let cluster = activeCluster else { return }
        if let existingPerson = attendees.first(where: { $0.displayName == cluster.label || $0.id == cluster.personId }) {
            confirmCluster(cluster, asPerson: existingPerson)
        } else {
            let p = Person(displayName: cluster.label)
            attendees.append(p)
            confirmCluster(cluster, asPerson: p)
        }
    }
    
    private func confirmCluster(_ cluster: SpeakerCluster, asPerson person: Person) {
        guard let idx = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[idx].label = person.displayName
        clusters[idx].personId = person.id
        clusters[idx].assignment = "user"
        clusters[idx].confidence = 1.0
        
        onAssign(cluster.id, person)
        onReassignUtterances(cluster.id, person.displayName)
        
        if learnFromConfirmedVoice && !cluster.centroid.isEmpty {
            onLockAndEnroll(clusters)
        }
        
        // Advance to next unconfirmed cluster
        if let nextIdx = clusters.firstIndex(where: { $0.assignment != "user" }) {
            activeClusterIndex = nextIdx
        }
    }
    
    private func markClusterUnknown(_ cluster: SpeakerCluster) {
        guard let idx = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        clusters[idx].label = "Unknown Speaker"
        clusters[idx].personId = nil
        clusters[idx].assignment = "unknown"
        onReassignUtterances(cluster.id, "Unknown Speaker")
    }
    
    private func toggleSamplePlayback(sample: Utterance) {
        if let path = meeting.audioPath {
            try? playback.loadAudio(path: path)
        }
        if isPlayingThisSample(sample) {
            playback.pause()
        } else {
            playback.play(from: sample.start, to: sample.end)
        }
    }
    
    private func isPlayingThisSample(_ sample: Utterance) -> Bool {
        return playback.isPlaying && playback.currentTime >= sample.start && playback.currentTime <= sample.end
    }
    
    // MARK: - Components
    
    private var waveformBars: some View {
        HStack(spacing: 3) {
            ForEach(0..<45, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MinutesTheme.primary.opacity(0.7))
                    .frame(width: 3, height: max(6, CGFloat(abs(sin(Double(i) * 0.4) * cos(Double(i) * 0.15)) * 36)))
            }
        }
        .frame(height: 40)
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func statusPill(_ assignment: String) -> some View {
        switch assignment {
        case "user":
            Text("Confirmed")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MinutesTheme.emerald.opacity(0.15))
                .foregroundStyle(MinutesTheme.emerald)
                .clipShape(Capsule())
        case "unknown":
            Text("Unknown")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.15))
                .foregroundStyle(Color.gray)
                .clipShape(Capsule())
        default:
            Text("Suggested")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule())
        }
    }
    
    private var totalSpeechDuration: Double {
        clusters.reduce(0.0) { $0 + $1.speechSeconds }
    }
    
    private func formatSpeechSeconds(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        return "\(max(1, mins)) min"
    }
    
    private func formatDuration(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        return "\(max(1, mins)) minutes"
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
    
    private func initialsFor(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
    
    private func avatarColorFor(_ name: String) -> Color {
        let hash = abs(name.hashValue)
        let colors = [MinutesTheme.primary, MinutesTheme.purple, MinutesTheme.emerald, Color.indigo, Color.teal]
        return colors[hash % colors.count]
    }
}
#endif
