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
    @State public var voiceprints: [Voiceprint]
    
    // Diarization Sensitivity Settings
    @State public var diarizationConfig: DiarizationConfig
    
    public let onAssign: (String, Person) -> Void
    public let onLockAndEnroll: ([SpeakerCluster]) -> Void
    public let onApplyDiarizationConfig: ((DiarizationConfig) -> Void)?
    
    private let matcher = SpeakerMatcher()
    
    public init(
        meeting: Meeting,
        clusters: [SpeakerCluster],
        attendees: [Person],
        voiceprints: [Voiceprint] = [],
        diarizationConfig: DiarizationConfig = DiarizationConfig(),
        onAssign: @escaping (String, Person) -> Void,
        onLockAndEnroll: @escaping ([SpeakerCluster]) -> Void,
        onApplyDiarizationConfig: ((DiarizationConfig) -> Void)? = nil
    ) {
        self.meeting = meeting
        self._clusters = State(initialValue: clusters)
        self._attendees = State(initialValue: attendees)
        self._voiceprints = State(initialValue: voiceprints)
        self._diarizationConfig = State(initialValue: diarizationConfig)
        self.onAssign = onAssign
        self.onLockAndEnroll = onLockAndEnroll
        self.onApplyDiarizationConfig = onApplyDiarizationConfig
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speaker Review & Attendee Mapping")
                            .font(.title2.bold())
                            .foregroundStyle(MinutesTheme.text)
                        Text("Drag and drop calendar attendees onto speaker clusters or use auto-mapping. Lock to enroll voiceprints.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    Spacer()
                    
                    HStack(spacing: 10) {
                        Button(action: runAutoMapping) {
                            Label("Auto-Map Attendees", systemImage: "sparkles")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: { onLockAndEnroll(clusters) }) {
                            Label("Lock & Enroll Voiceprints", systemImage: "checkmark.seal.fill")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MinutesTheme.primary)
                    }
                }
                
                // Calendar Attendees Strip (Draggable)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(MinutesTheme.primary)
                        Text("CALENDAR ATTENDEES (DRAG TO ASSIGN)")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.muted)
                        Spacer()
                        Text("\(attendees.count) Attendees")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(attendees) { person in
                                attendeeChip(person)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .minutesCard()
                
                // Detected Voice Clusters (Drop Destinations)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(MinutesTheme.emerald)
                        Text("DETECTED VOICE CLUSTERS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.emerald)
                        Spacer()
                        Text("\(clusters.count) Voice Clusters")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    ForEach(clusters) { cluster in
                        clusterDropTargetRow(cluster)
                    }
                }
                .padding(16)
                .minutesCard()
                
                // Diarization Sensitivity Controls
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(MinutesTheme.purple)
                        Text("DIARIZATION SENSITIVITY CONTROLS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.purple)
                        Spacer()
                        if let onApply = onApplyDiarizationConfig {
                            Button("Apply Sensitivity") {
                                onApply(diarizationConfig)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption.bold())
                        }
                    }
                    
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Pause Threshold:")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(String(format: "%.1f seconds", diarizationConfig.pauseThreshold))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(MinutesTheme.primary)
                                }
                                Slider(value: $diarizationConfig.pauseThreshold, in: 0.5...3.5, step: 0.1)
                                Text("Controls silence duration before segmenting speaker turns (default: 1.8s).")
                                    .font(.caption)
                                    .foregroundStyle(MinutesTheme.muted)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Aggressiveness:")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(String(format: "%.2f", diarizationConfig.aggressiveness))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(MinutesTheme.purple)
                                }
                                Slider(value: $diarizationConfig.aggressiveness, in: 0.0...1.0, step: 0.05)
                                Text("Higher values reject brief non-speech noise and prioritize dominant speaker.")
                                    .font(.caption)
                                    .foregroundStyle(MinutesTheme.muted)
                            }
                        }
                    }
                }
                .padding(16)
                .minutesCard()
            }
            .padding(20)
        }
        .background(MinutesTheme.bg)
    }
    
    // MARK: - Attendee Chip (Draggable)
    
    @ViewBuilder
    private func attendeeChip(_ person: Person) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(person.isMe ? MinutesTheme.emerald : MinutesTheme.blue)
                .frame(width: 8, height: 8)
            Text(person.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MinutesTheme.text)
            if person.isMe {
                Text("HOST")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(MinutesTheme.emerald.opacity(0.2))
                    .foregroundStyle(MinutesTheme.emerald)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MinutesTheme.cardHover)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MinutesTheme.border, lineWidth: 1))
        .draggable(person.id)
    }
    
    // MARK: - Cluster Drop Target Row
    
    @ViewBuilder
    private func clusterDropTargetRow(_ cluster: SpeakerCluster) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(cluster.label)
                        .font(.headline)
                        .foregroundStyle(MinutesTheme.text)
                    assignmentBadge(cluster.assignment, confidence: cluster.confidence)
                }
                Text(String(format: "%.1f seconds spoken · %d-dim centroid", cluster.speechSeconds, cluster.centroid.count))
                    .font(.caption)
                    .foregroundStyle(MinutesTheme.muted)
            }
            
            Spacer()
            
            // Interactive Selector Menu
            Menu {
                ForEach(attendees) { person in
                    Button(person.displayName) {
                        assign(person: person, to: cluster.id)
                    }
                }
            } label: {
                HStack {
                    Text(cluster.personId != nil ? cluster.label : "Assign Attendee...")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(MinutesTheme.cardHover)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(MinutesTheme.border, lineWidth: 1))
            }
        }
        .padding(14)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { items, _ in
            guard let personId = items.first,
                  let person = attendees.first(where: { $0.id == personId }) else {
                return false
            }
            assign(person: person, to: cluster.id)
            return true
        }
    }
    
    private func assign(person: Person, to clusterId: String) {
        onAssign(clusterId, person)
        if let idx = clusters.firstIndex(where: { $0.id == clusterId }) {
            clusters[idx].label = person.displayName
            clusters[idx].personId = person.id
            clusters[idx].assignment = "user"
        }
    }
    
    private func runAutoMapping() {
        let attendeeIds = Set(attendees.map { $0.id })
        let matches = matcher.match(
            clusters: clusters,
            people: attendees,
            voiceprints: voiceprints,
            attendeePersonIds: attendeeIds
        )
        
        for m in matches {
            guard let pId = m.personId,
                  let person = attendees.first(where: { $0.id == pId }),
                  let idx = clusters.firstIndex(where: { $0.id == m.clusterId }) else {
                continue
            }
            clusters[idx].label = person.displayName
            clusters[idx].personId = person.id
            clusters[idx].assignment = m.assignment
            clusters[idx].confidence = m.confidence
            onAssign(clusters[idx].id, person)
        }
    }
    
    private func colorForAssignment(_ assignment: String) -> Color {
        switch assignment {
        case "auto": return MinutesTheme.emerald
        case "user": return MinutesTheme.primary
        default: return Color.orange
        }
    }
    
    @ViewBuilder
    private func assignmentBadge(_ assignment: String, confidence: Double) -> some View {
        let color = colorForAssignment(assignment)
        Text("\(assignment.uppercased()) (\(Int(confidence * 100))%)")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
#endif
