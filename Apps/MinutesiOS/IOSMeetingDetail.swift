import SwiftUI
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesCalendar
import MinutesUI

struct IOSMeetingDetail: View {
    @ObservedObject var state: AppState
    let meetingID: String
    var showsRecording = false
    @State private var transcriptFindRequest = 0
    @State private var view = "Notes"
    @State private var moveError: String?
    @State private var confirmingRegeneration = false

    var body: some View {
        Group {
            if view == "Transcript" { transcript }
            else if view == "Speakers" { IOSSpeakerReview(state: state) }
            else if let meeting = state.currentMeeting, meeting.id == meetingID {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if (showsRecording || state.activeRecordingMeetingID == meetingID) && (state.isRecording || state.isStartingRecording || state.isPreparingRecording) {
                            IOSRecordingWorkspace(state: state)
                            Divider().padding(.vertical, 8)
                        }
                        if !state.isRecording && ["failed", "interrupted"].contains(meeting.status) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(meeting.status == "interrupted" ? "Recording was interrupted" : "Recording did not finish", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text(state.statusMessage == "Ready" ? "Any saved audio is preserved. You can process a recovery copy or start a new recording." : state.statusMessage)
                                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if hasSavedAudio {
                                    Button("Process Saved Audio", systemImage: "waveform") { Task { await state.processCurrentMeeting() } }
                                        .disabled(state.isProcessing || state.isFinalizingRecording)
                                }
                                if showsRecording {
                                    Button("Try a New Recording", systemImage: "record.circle") {
                                        Task { if await state.prepareRecording() { state.startQuickMeeting() } }
                                    }.disabled(!state.canStartRecording)
                                }
                            }.padding(18).minutesControlGlass(in: RoundedRectangle(cornerRadius: 20))
                        }
                        TextField("Meeting title", text: Binding(get: { state.currentMeeting?.title ?? meeting.title }, set: { title in
                            save { guard var latest = state.store.getMeeting(id: meetingID) else { return }; latest.title = title; try state.store.saveMeeting(latest); state.selectMeeting(id: meetingID) }
                        }), axis: .vertical).font(.system(size: 28, weight: .bold)).lineLimit(1...3)
                            .textFieldStyle(.plain).accessibilityLabel("Meeting title")
                        Menu {
                            MeetingFolderDestinations(folders: state.folders) { folderID in
                                do { try state.moveMeeting(meetingID, to: folderID) } catch { moveError = error.localizedDescription }
                            }
                        } label: { Label(state.folderName(for: meetingID), systemImage: "folder").font(.subheadline).foregroundStyle(.secondary) }
                        NotesView(meeting: meeting, summary: state.currentSummary, utterances: state.currentUtterances, attendees: state.currentAttendees, bookmarks: state.currentBookmarks,
                            onSaveNotes: { text in save { guard var latest = state.store.getMeeting(id: meetingID) else { return }; latest.userNotes = text; try state.store.saveMeeting(latest); state.selectMeeting(id: meetingID) } },
                            onSaveBookmark: { bookmark in save { try state.store.saveBookmark(bookmark); state.currentBookmarks = state.store.listBookmarks(meetingId: meetingID) } },
                            onDeleteBookmark: { id in save { try state.store.deleteBookmark(id: id); state.currentBookmarks = state.store.listBookmarks(meetingId: meetingID) } },
                            onGenerateSummary: { Task { await state.generateCurrentSummary() } },
                            onExportMarkdown: { Task { _ = await state.exportCurrentMeeting(target: "markdown") } },
                            onExportParachute: { Task { _ = await state.exportCurrentMeeting(target: "parachute") } },
                            onSaveSummary: { markdown in save { guard var summary = state.currentSummary else { return }; summary.markdown = markdown; try state.store.saveSummary(summary); state.currentSummary = summary } },
                            isSummarizing: state.isSummarizing,
                playbackAllowed: !state.isRecording && !state.isStartingRecording && !state.isFinalizingRecording,
                            usesAppleIntelligence: state.summaryUsesAppleIntelligence,
                            onEnableAppleSummary: { state.summaryUsesAppleIntelligence = true; Task { await state.generateCurrentSummary() } },
                            onFindTranscript: findInTranscript,
                            onRegenerateRecording: { confirmingRegeneration = true },
                            isProcessingRecording: state.isProcessing || state.isSummarizing)
                    }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 80).id(meetingID)
                }.background(MinutesTheme.document)
            } else { ProgressView() }
        }
        .navigationTitle(view == "Notes" ? "" : view)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { state.selectMeeting(id: meetingID) }
        .safeAreaInset(edge: .bottom) {
            if state.isProcessing || state.isSummarizing || state.isFinalizingRecording {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(state.statusMessage).font(.caption) }
                    .padding(14).frame(maxWidth: .infinity)
                    .minutesControlGlass(in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            } else if !state.isRecording && state.statusMessage != "Ready" &&
                !(view == "Notes" && ["failed", "interrupted"].contains(state.currentMeeting?.status ?? "")) {
                HStack {
                    Text(state.statusMessage).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { state.statusMessage = "Ready" } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss message")
                }.foregroundStyle(.secondary).padding(14)
                    .minutesControlGlass(in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .task(id: state.statusMessage) {
                        let saved = state.statusMessage
                        guard saved.hasPrefix("Recording and ") || saved.hasPrefix("Recording processed") || saved.hasPrefix("On-device AI draft saved") else { return }
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, state.statusMessage == saved else { return }
                        state.statusMessage = "Ready"
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Picker("Meeting view", selection: $view) {
                    Label("Notes", systemImage: "note.text").tag("Notes")
                    Label("Transcript", systemImage: "text.alignleft").tag("Transcript")
                    Label("Speakers", systemImage: "person.2").tag("Speakers")
                }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Meeting view")
                Menu {
                    if let path = state.currentMeeting?.audioPath, FileManager.default.fileExists(atPath: path) {
                        ShareLink(item: URL(fileURLWithPath: path)) {
                            Label("Share Original Audio", systemImage: "waveform")
                        }
                    }
                    if !state.currentUtterances.isEmpty {
                        ShareLink(item: state.currentUtterances.map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n\n"))
                    }
                    Button("Export to Prism", systemImage: "square.and.arrow.up") { Task { _ = await state.exportCurrentMeeting(target: "prism") } }.disabled(!state.prismVerified || state.prismBusy)
                } label: { Label("Share meeting", systemImage: "square.and.arrow.up") }

            }
        }
        .confirmationDialog("Regenerate from recording?", isPresented: $confirmingRegeneration, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                guard state.currentMeeting?.id == meetingID else { return }
                Task { await state.processCurrentMeeting() }
            }
        } message: { Text("This reprocesses the saved audio and updates its transcript, speakers and automatic summary. Review any transcript edits and speaker choices afterward. Your notes are kept.") }
        .alert("Could not move meeting", isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
            Button("OK") { moveError = nil }
        } message: { Text(moveError ?? "") }
    }
    private var hasSavedAudio: Bool {
        guard let path = state.currentMeeting?.audioPath,
              let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        // The app's PCM microphone WAV has a 4096-byte header. Header-only
        // failed captures cannot yield a transcript or recovery copy.
        return size > 4096
    }
    private func findInTranscript() {
        view = "Transcript"
        transcriptFindRequest += 1
    }
    private var transcript: some View {
        TranscriptView(utterances: state.currentUtterances, availableSpeakers: state.currentClusters.map(\.label),
            clusters: state.currentClusters, timestampsAvailable: state.currentMeeting?.platform != "transcript_import",
            findRequest: transcriptFindRequest,
            onSeek: { time in
                guard !state.isRecording && !state.isStartingRecording && !state.isFinalizingRecording,
                      let meeting = state.currentMeeting, meeting.platform != "transcript_import", let path = meeting.audioPath else { return }
                save {
                    try AudioPlaybackService.shared.loadAudio(path: path)
                    AudioPlaybackService.shared.play(from: time)
                }
            },
            onUtteranceEdited: { updated in
                save {
                    try state.store.saveUtterances([updated])
                    state.selectMeeting(id: meetingID)
                }
            })
            .id(meetingID)
    }
    private func save(_ operation: () throws -> Void) {
        do {
            try operation()
            if let meeting = state.currentMeeting, let index = state.meetings.firstIndex(where: { $0.id == meeting.id }) {
                state.meetings[index] = meeting
            }
        } catch { state.statusMessage = "Could not save: \(error.localizedDescription)" }
    }
}

private struct IOSSpeakerReview: View {
    @ObservedObject var state: AppState

    var body: some View {
        List {
            Section {
                ForEach(state.currentClusters) { cluster in
                    NavigationLink {
                        IOSSpeakerAssignment(state: state, cluster: cluster)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cluster.label).font(.headline)
                            Label(cluster.assignment == "user" ? "Confirmed by you" :
                                  (cluster.assignment == "auto" ? "Remembered voice · needs confirmation" : "Name needs review"),
                                  systemImage: cluster.assignment == "user" ? "checkmark.circle" : "person.crop.circle.badge.questionmark")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(Duration.seconds(cluster.speechSeconds.isFinite ? max(0, cluster.speechSeconds) : 0),
                                 format: .time(pattern: .minuteSecond))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            } header: {
                Text("\(state.currentClusters.filter { $0.assignment == "user" }.count) of \(state.currentClusters.count) confirmed")
            } footer: {
                Text("Choose a speaker, listen to their sample, then confirm who spoke. Calendar invitees may be absent.")
            }
        }
        .navigationTitle("Speakers")
        .overlay {
            if state.currentClusters.isEmpty {
                ContentUnavailableView("No speakers yet", systemImage: "person.wave.2",
                    description: Text("Speakers appear after a recording is transcribed."))
            }
        }
    }
}

private struct IOSSpeakerAssignment: View {
    @ObservedObject var state: AppState
    let cluster: SpeakerCluster
    @Environment(\.dismiss) private var dismiss
    @State private var existingPersonID = ""
    @State private var name = ""
    @State private var email = ""
    @State private var learn = false
    @State private var error: String?

    init(state: AppState, cluster: SpeakerCluster) {
        self.state = state
        self.cluster = cluster
        let savedPerson = cluster.personId.flatMap { state.store.getPerson(id: $0) }
        self._existingPersonID = State(initialValue: savedPerson?.id ?? "")
        self._name = State(initialValue: savedPerson?.displayName ?? "")
        self._email = State(initialValue: savedPerson?.emails.first ?? "")
    }

    var body: some View {
        Form {
            Section {
                if let meeting = state.currentMeeting {
                    VoiceSamplePlaybackView(meeting: meeting, cluster: cluster,
                        utterances: state.currentUtterances,
                        playbackAllowed: !state.isRecording && !state.isStartingRecording && !state.isFinalizingRecording)
                }
                if let sample = sampleText {
                    Text(sample).font(.body).lineSpacing(4).textSelection(.enabled)
                }
            } header: {
                Text("Listen before confirming")
            }
            Section {
                Picker("Person", selection: $existingPersonID) {
                    Text("Enter a new name").tag("")
                    if !meetingPeople.isEmpty {
                        Section("Linked to this meeting") {
                            ForEach(meetingPeople) { person in Text(person.displayName).tag(person.id) }
                        }
                    }
                    if !otherPeople.isEmpty {
                        Section("Saved people") {
                            ForEach(otherPeople) { person in Text(person.displayName).tag(person.id) }
                        }
                    }
                }
                if existingPersonID.isEmpty {
                    TextField("Speaker name", text: $name)
                        .textContentType(.name)
                    TextField("Email (optional)", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                }
            } header: {
                Text("Who is speaking?")
            } footer: {
                Text("Calendar invitations suggest people to choose from. They do not identify a voice or confirm attendance.")
            }
            Section {
                Toggle("Remember this voice", isOn: $learn).disabled(!canRememberVoice)
            } footer: {
                Text(canRememberVoice ? "Optional. Saved on this device only after you confirm this name." : "Remembering a voice needs a current sample with at least 20 seconds of usable speech. You can still confirm this speaker’s name.")
            }
            Section {
                Button(action: confirm) {
                    Label(learn ? "Confirm and remember voice" : "Confirm speaker", systemImage: "checkmark")
                        .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain)
                    .disabled(existingPersonID.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Keep unknown", action: keepUnknown)
                    .disabled(cluster.assignment == "unknown")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(cluster.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sampleText: String? {
        guard let sample = SpeakerAudioSample(utterances: state.currentUtterances, clusterID: cluster.id) else { return nil }
        return state.currentUtterances.first { $0.clusterId == cluster.id && $0.start == sample.start && $0.end >= sample.end }?.text
    }

    private var meetingPeople: [Person] {
        let linked = Set(state.currentAttendees.map(\.id))
        return state.store.listPeople().filter { linked.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var otherPeople: [Person] {
        let linked = Set(meetingPeople.map(\.id))
        return state.store.listPeople().filter { !linked.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func confirm() {
        guard let meeting = state.currentMeeting else { return }
        let people = state.store.listPeople()
        let normalizedEmail = NameResolver.cleanEmail(email)
        let person = people.first(where: { $0.id == existingPersonID }) ??
            people.first(where: { !normalizedEmail.isEmpty && $0.emails.contains { NameResolver.cleanEmail($0) == normalizedEmail } }) ??
            Person(id: UUID().uuidString.lowercased(), displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                   emails: normalizedEmail.isEmpty ? [] : [normalizedEmail])
        do {
            try state.store.withImmediateTransaction {
                var current = try currentSample(meetingID: meeting.id)
                current.label = person.displayName
                current.personId = person.id
                current.assignment = "user"
                current.confidence = 1
                try state.store.savePerson(person)
                try state.store.saveSpeakerClusters([current])
                var utterances = state.store.listUtterances(meetingId: meeting.id)
                for i in utterances.indices where utterances[i].clusterId == cluster.id {
                    utterances[i].speakerName = person.displayName
                }
                try state.store.saveUtterances(utterances)
                if learn {
                    try VoiceEnrollment.remember(store: state.store, personID: person.id,
                        meetingID: meeting.id, clusterID: current.id, expected: current)
                }
            }
            state.voiceprints = state.store.listVoiceprints()
            state.selectMeeting(id: meeting.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func keepUnknown() {
        guard let meeting = state.currentMeeting else { return }
        do {
            try state.store.withImmediateTransaction {
                var current = try currentSample(meetingID: meeting.id)
                current.label = "Unknown speaker"
                current.personId = nil
                current.assignment = "unknown"
                current.confidence = 0
                try state.store.saveSpeakerClusters([current])
                var utterances = state.store.listUtterances(meetingId: meeting.id)
                for i in utterances.indices where utterances[i].clusterId == cluster.id {
                    utterances[i].speakerName = "Unknown speaker"
                }
                try state.store.saveUtterances(utterances)
            }
            state.selectMeeting(id: meeting.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func currentSample(meetingID: String) throws -> SpeakerCluster {
        guard meetingID == cluster.meetingId,
              let current = state.store.listSpeakerClusters(meetingId: meetingID).first(where: { $0.id == cluster.id }) else {
            throw VoiceEnrollmentError.missingSample
        }
        guard current.embeddingModel == cluster.embeddingModel,
              current.centroid.map(\.bitPattern) == cluster.centroid.map(\.bitPattern),
              current.speechSeconds.bitPattern == cluster.speechSeconds.bitPattern, current.personId == cluster.personId,
              current.assignment == cluster.assignment else { throw VoiceEnrollmentError.changedSample }
        return current
    }

    private var canRememberVoice: Bool { VoiceEnrollment.isEligible(cluster) }
}
