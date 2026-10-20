#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeakerID
import MinutesSpeech

@available(macOS 15.0, iOS 18.0, *)
public struct VoiceprintHubView: View {
    public let store: MinutesStore
    @State public var voiceprints: [Voiceprint] = []
    @State public var people: [Person] = []
    @State public var clusters: [SpeakerCluster] = []
    @State public var utterances: [Utterance] = []
    @State public var selectedVoiceprintId: String? = nil
    
    // Merge State
    @State private var showingMergeSheet = false
    @State private var mergeSourceClusterIds: Set<String> = []
    @State private var mergeTargetName: String = ""
    
    // Split State
    @State private var showingSplitSheet = false
    @State private var splitClusterId: String = ""
    @State private var splitTimestamp: Double = 60.0
    
    // Delete Confirmation
    @State private var voiceprintToDelete: Voiceprint? = nil
    @State private var showingDeleteAlert = false
    
    @State private var fallbackSelection: String?
    private let externalSelection: Binding<String?>?
    private let showsList: Bool
    private let playbackAllowed: Bool
    @State private var showingVoicePicker = false
    @State private var voiceCandidates: [VoiceEnrollmentCandidate] = []
    @State private var confirmingVoice: VoiceEnrollmentCandidate?
    private let onOpenMeeting: ((Meeting) -> Void)?
    @State private var recentMeetings: [PersonMeetingHistoryEntry] = []
    @State private var showingAllMeetings = false
    @State private var meetingSearch = ""
    @State private var historyError: String?
    @State private var operationError: String?
    @State private var operationFeedback: String?

    private let clusterManager = ClusterManager()
    private let meetingId: String?
    
    public init(
        store: MinutesStore,
        meetingId: String? = nil,
        voiceprints: [Voiceprint] = [],
        people: [Person] = [],
        clusters: [SpeakerCluster] = [],
        utterances: [Utterance] = [],
        selection: Binding<String?>? = nil,
        showsList: Bool = true,
        onOpenMeeting: ((Meeting) -> Void)? = nil,
        playbackAllowed: Bool = true
    ) {
        self.store = store
        self.playbackAllowed = playbackAllowed
        self.meetingId = meetingId
        self.externalSelection = selection
        self.showsList = showsList
        self.onOpenMeeting = onOpenMeeting
        self._voiceprints = State(initialValue: voiceprints)
        self._people = State(initialValue: people)
        self._clusters = State(initialValue: clusters)
        self._utterances = State(initialValue: utterances)
    }
    
    private var personSelection: Binding<String?> {
        externalSelection ?? $fallbackSelection
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showsList {
                List(selection: personSelection) {
                ForEach(people) { person in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.displayName)
                        Text(person.emails.first ?? (person.isMe ? "Me" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(person.id)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                Divider()
            }
            ScrollView {
                if let person = people.first(where: { $0.id == personSelection.wrappedValue }) {
                    personDetails(person)
                } else {
                    ContentUnavailableView(
                        people.isEmpty ? "No people yet" : "Select a person",
                        systemImage: "person.crop.circle",
                        description: Text(people.isEmpty ? "People appear when you record a calendar meeting or name a speaker." : "View recorded meetings, contact details and remembered voices.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
        }
        .background(MinutesTheme.document)
        .onAppear { refreshData() }
        .onChange(of: personSelection.wrappedValue) { _, _ in
            operationFeedback = nil
            refreshMeetingHistory()
        }
        .sheet(isPresented: $showingVoicePicker) { voicePicker }
        .sheet(isPresented: $showingMergeSheet) { mergeSheetView }
        .sheet(isPresented: $showingSplitSheet) { splitSheetView }
        .alert("Forget this voice?", isPresented: $showingDeleteAlert, presenting: voiceprintToDelete) { voiceprint in
            Button("Forget voice", role: .destructive) {
                do {
                    try store.deleteVoiceprint(id: voiceprint.id)
                    operationFeedback = "Voice forgotten. This person’s meeting history is unchanged."
                    refreshData()
                } catch {
                    operationError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This voice sample will no longer be used to recognize this person in future meetings.")
        }
        .alert("Couldn’t save changes", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private func personDetails(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName).font(.title.weight(.semibold))
                    Text(person.isMe ? "Your profile" : "Person")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !person.emails.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(person.emails, id: \.self) { email in
                        Text(email).textSelection(.enabled)
                    }
                }
            }
            meetingHistorySection
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Voice recognition").font(.headline)
                        Spacer(minLength: 8)
                        connectVoiceButton(person)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Voice recognition").font(.headline)
                        connectVoiceButton(person)
                    }
                }
                if let operationFeedback {
                    Label(operationFeedback, systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Saved on this device. Voice profiles aren’t synced between your Mac and iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
                let savedVoices = voiceprints.filter { $0.personId == person.id }
                if savedVoices.isEmpty {
                    Text("No remembered voice")
                        .font(.callout.weight(.medium))
                    Text("Choose Connect voice to select and confirm a speaker from a recorded meeting. Samples need at least 20 seconds of usable speech. Nothing is remembered until you confirm.")
                        .foregroundStyle(.secondary)
                }
                if !savedVoices.isEmpty {
                    Label("\(savedVoices.count) remembered \(savedVoices.count == 1 ? "voice" : "voices")", systemImage: "waveform")
                        .font(.callout.weight(.medium))
                    let eligibleCount = savedVoices.filter { SpeakerReviewPresentation.profileWarning($0) == nil }.count
                    Text(eligibleCount == 0 ? "No saved voice is eligible for automatic recognition yet. Record and confirm a new sample to enable it." : "Strong matches fill speaker names automatically in future transcripts. You can confirm or correct them in People within each meeting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(savedVoices) { voiceprint in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(voiceprint.createdAt, style: .date).font(.callout.weight(.medium))
                            Text("\(SpeakerReviewPresentation.speechDuration(voiceprint.speechSeconds)) of speech")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let warning = SpeakerReviewPresentation.profileWarning(voiceprint) {
                                Text(warning)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Forget…", role: .destructive) {
                            voiceprintToDelete = voiceprint
                            showingDeleteAlert = true
                        }
                    }
                    Divider()
                }
            }
            if meetingId != nil && !clusters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speakers in this meeting").font(.headline)
                    ForEach(clusters.filter { $0.personId == person.id }) { cluster in
                        Text(cluster.label)
                    }
                    HStack {
                        Button("Merge speakers…") {
                            mergeSourceClusterIds = Set(clusters.prefix(2).map { $0.id })
                            mergeTargetName = person.displayName
                            showingMergeSheet = true
                        }
                        .disabled(clusters.count < 2)
                        Button("Split speaker…") {
                            guard let first = clusters.first(where: { $0.personId == person.id }) ?? clusters.first else { return }
                            splitClusterId = first.id
                            let segments = utterances.filter { $0.clusterId == first.id }
                            splitTimestamp = ((segments.map(\.start).min() ?? 0) + (segments.map(\.end).max() ?? 2)) / 2
                            showingSplitSheet = true
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
    }

    private func connectVoiceButton(_ person: Person) -> some View {
        Button {
            voiceCandidates = VoiceEnrollment.candidates(store: store, personID: person.id)
            showingVoicePicker = true
        } label: {
            Label("Connect voice", systemImage: "waveform.badge.plus")
                .font(.callout.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }.buttonStyle(.plain).fixedSize()
    }

    private var meetingHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(spacing: 12) {
                Text(recentMeetings.isEmpty ? "Meetings together" : "Meetings together · \(recentMeetings.count)").font(.headline)
                Spacer(minLength: 0)
                Button(action: refreshMeetingHistory) {
                    Image(systemName: "arrow.clockwise").font(.callout)
                        .frame(width: 30, height: 30)
                        .minutesControlGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).accessibilityLabel("Refresh this person’s recorded meetings")
            }
            if let historyError {
                Text("Couldn’t load recorded meetings. \(historyError)")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try again", action: refreshMeetingHistory).buttonStyle(.plain)
            } else if recentMeetings.isEmpty {
                Text("No linked recordings yet")
                    .font(.callout.weight(.medium))
                Text("Calendar invitations and speaker assignments link local recordings to this person.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if showingAllMeetings && recentMeetings.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search these meetings", text: $meetingSearch).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .minutesControlGlass(in: Capsule())
                }
                ForEach(visibleMeetings) { entry in
                    VStack(alignment: .leading, spacing: 12) {
                        if let onOpenMeeting {
                            Button { onOpenMeeting(entry.meeting) } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    meetingHistoryLabel(entry)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.forward")
                                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityHint("Open this recorded meeting")
                        } else {
                            meetingHistoryLabel(entry)
                        }
                        Divider()
                    }
                }
                if recentMeetings.count > 6 {
                    Button { withAnimation(.snappy) { showingAllMeetings.toggle(); meetingSearch = "" } } label: {
                        Label(showingAllMeetings ? "Show recent only" : "Show all \(recentMeetings.count) meetings",
                              systemImage: showingAllMeetings ? "chevron.up" : "list.bullet")
                            .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 36)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain)
                }
                Text("A calendar invitation does not confirm attendance. Voice assignments can be reviewed in each recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The six latest, or every meeting with this person (optionally searched).
    private var visibleMeetings: [PersonMeetingHistoryEntry] {
        guard showingAllMeetings else { return Array(recentMeetings.prefix(6)) }
        let query = meetingSearch.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? recentMeetings : recentMeetings.filter { $0.meeting.title.localizedCaseInsensitiveContains(query) }
    }

    private func meetingHistoryLabel(_ entry: PersonMeetingHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.meeting.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
            Text(entry.meeting.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { meetingContexts(entry) }
                VStack(alignment: .leading, spacing: 4) { meetingContexts(entry) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }

    @ViewBuilder private func meetingContexts(_ entry: PersonMeetingHistoryEntry) -> some View {
        if entry.calendarInvitee {
            Label("Calendar invitee", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
        }
        if entry.confirmedSpeaker {
            Label("Confirmed speaker", systemImage: "person.crop.circle.badge.checkmark").font(.caption).foregroundStyle(.secondary)
        }
        if entry.recognizedSpeaker {
            Label("Recognized voice", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
        }
        if entry.speakerLinked && !entry.confirmedSpeaker && !entry.recognizedSpeaker {
            Label("Speaker association needs review", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshMeetingHistory() {
        guard let personID = personSelection.wrappedValue else {
            recentMeetings = []; historyError = nil; return
        }
        do {
            recentMeetings = try store.listMeetings(forPersonId: personID, limit: .max)
            showingAllMeetings = false; meetingSearch = ""
            historyError = nil
        } catch {
            recentMeetings = []
            historyError = error.localizedDescription
        }
    }

    private var voicePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose a recorded speaker").font(.title2.bold())
                    Text("Listen to a sample, then confirm it belongs to this person. Their voice stays on this device and helps identify future meetings.")
                        .font(.callout).foregroundStyle(.secondary)
                    if voiceCandidates.isEmpty {
                        ContentUnavailableView("No eligible samples yet", systemImage: "waveform",
                            description: Text("Record at least 20 seconds of clear speech, finish transcription, then return here. Older voice models and speakers assigned to someone else are excluded."))
                    }
                    ForEach(voiceCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(candidate.meeting.title).font(.headline).lineLimit(2)
                            Text(candidate.meeting.startedAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(candidate.cluster.label) · \(SpeakerReviewPresentation.speechDuration(candidate.cluster.speechSeconds)) of speech")
                                .font(.callout).foregroundStyle(.secondary)
                            VoiceSamplePlaybackView(meeting: candidate.meeting, cluster: candidate.cluster,
                                utterances: store.listUtterances(meetingId: candidate.meeting.id),
                                playbackAllowed: playbackAllowed)
                            Button { confirmingVoice = candidate } label: {
                                Label("Use this voice", systemImage: "checkmark")
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .minutesControlGlass(in: Capsule(), interactive: true)
                            }.buttonStyle(.plain)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .minutesControlGlass(in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(24)
            }
            .navigationTitle("Connect a voice")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingVoicePicker = false } } }
            .alert("Remember this voice?", isPresented: Binding(get: { confirmingVoice != nil }, set: { if !$0 { confirmingVoice = nil } })) {
                Button("Remember voice") {
                    guard let sample = confirmingVoice, let personID = personSelection.wrappedValue else { return }
                    do {
                        try VoiceEnrollment.remember(store: store, personID: personID, meetingID: sample.meeting.id,
                            clusterID: sample.cluster.id, expected: sample.cluster)
                        operationFeedback = "Voice connected. Future meetings can recognize this person."
                        confirmingVoice = nil; showingVoicePicker = false; refreshData()
                    } catch { operationError = error.localizedDescription; confirmingVoice = nil; showingVoicePicker = false }
                }
                Button("Cancel", role: .cancel) { confirmingVoice = nil }
            } message: {
                Text("Confirm this is \(people.first(where: { $0.id == personSelection.wrappedValue })?.displayName ?? "this person") speaking. This assigns the selected speaker and saves a local voice profile. Only remember someone’s voice with their consent.")
            }
        }.frame(idealWidth: 580, idealHeight: 620)
    }

    // MARK: - Merge Sheet View
    
    private var mergeSheetView: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Combine speaker segments that belong to the same person.")
                    .font(.subheadline)
                    .foregroundStyle(MinutesTheme.muted)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker name")
                        .font(.caption.bold())
                    TextField("Speaker Name", text: $mergeTargetName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speakers to combine")
                        .font(.caption.bold())
                    ForEach(clusters) { c in
                        Toggle(isOn: Binding(
                            get: { mergeSourceClusterIds.contains(c.id) },
                            set: { on in
                                if on { mergeSourceClusterIds.insert(c.id) }
                                else { mergeSourceClusterIds.remove(c.id) }
                            }
                        )) {
                            Text("\(c.label) (\(SpeakerReviewPresentation.speechDuration(c.speechSeconds)))")
                        }
                    }
                }
                
                Spacer()
                
                Button("Merge speakers") {
                    let toMerge = clusters.filter { mergeSourceClusterIds.contains($0.id) }
                    guard toMerge.count >= 2 else { return }
                    
                    let merged = clusterManager.merge(clusters: toMerge, targetName: mergeTargetName)
                    
                    var newClusters = clusters.filter { !mergeSourceClusterIds.contains($0.id) }
                    newClusters.append(merged)
                    var updatedUtterances = utterances
                    for i in updatedUtterances.indices where mergeSourceClusterIds.contains(updatedUtterances[i].clusterId) {
                        updatedUtterances[i].clusterId = merged.id
                        updatedUtterances[i].speakerName = merged.label
                    }
                    do {
                        try store.withImmediateTransaction {
                            try store.saveSpeakerClusters(newClusters)
                            try store.saveUtterances(updatedUtterances)
                            for oldId in mergeSourceClusterIds { try store.deleteSpeakerCluster(id: oldId) }
                        }
                        showingMergeSheet = false
                        operationFeedback = "Speakers combined. Review the updated transcript to confirm the result."
                        refreshData()
                    } catch { operationError = error.localizedDescription }

                }
                .buttonStyle(.borderedProminent)
                .disabled(mergeSourceClusterIds.count < 2 || mergeTargetName.isEmpty)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Merge speakers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingMergeSheet = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }
    
    // MARK: - Split Sheet View
    
    private var splitSheetView: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Split a cluster into two distinct speakers at a given timestamp boundary.")
                    .font(.subheadline)
                    .foregroundStyle(MinutesTheme.muted)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker")
                        .font(.caption.bold())
                    Picker("", selection: $splitClusterId) {
                        ForEach(clusters) { c in
                            Text(c.label).tag(c.id)
                        }
                    }
                    .labelsHidden()
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    let targetCluster = clusters.first(where: { $0.id == splitClusterId })
                    let maxSecs = max(1, utterances.filter { $0.clusterId == targetCluster?.id }.map(\.end).max() ?? 1)
                    Text("Split at \(String(format: "%.1f", splitTimestamp)) seconds")
                        .font(.caption.bold())
                    Slider(value: $splitTimestamp, in: 0.0...maxSecs, step: 1.0)
                }
                
                Spacer()
                
                Button("Split speaker") {
                    guard let target = clusters.first(where: { $0.id == splitClusterId }) else { return }
                    let (c1, c2, updatedUtterances) = clusterManager.split(
                        cluster: target,
                        boundaryTimestamp: splitTimestamp,
                        utterances: utterances
                    )
                    
                    var newClusters = clusters.filter { $0.id != target.id }
                    newClusters.append(contentsOf: [c1, c2])
                    do {
                        try store.withImmediateTransaction {
                            try store.deleteSpeakerCluster(id: target.id)
                            try store.saveSpeakerClusters(newClusters)
                            try store.saveUtterances(updatedUtterances)
                        }
                        showingSplitSheet = false
                        operationFeedback = "Speaker split. Review both speakers in the meeting."
                        refreshData()
                    } catch { operationError = error.localizedDescription }

                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Split speaker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSplitSheet = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 340)
    }
    
    private func refreshData() {
        voiceprints = store.listVoiceprints()
        people = store.listPeople()
        if personSelection.wrappedValue == nil || !people.contains(where: { $0.id == personSelection.wrappedValue }) {
            personSelection.wrappedValue = people.first?.id
        }
        refreshMeetingHistory()
        if let targetId = meetingId {
            clusters = store.listSpeakerClusters(meetingId: targetId)
            utterances = store.listUtterances(meetingId: targetId)
        }
    }
}
#endif
