import SwiftUI
import MinutesCore
import MinutesSpeech
import MinutesUI
import MinutesCalendar
import MinutesExport
import MinutesSummarize
import UniformTypeIdentifiers

@MainActor
private final class IOSStartup: ObservableObject {
    @Published var state: AppState?
    @Published var error: String?
    /// Live Activity and live captions; created once alongside the library.
    private(set) var liveSurface: IOSLiveRecordingSurface?

    init() { retry() }
    func retry() {
        do {
            #if DEBUG
            state = try ProcessingAcceptance.enabled ? ProcessingAcceptance.makeState() : AppState()
            #else
            state = try AppState()
            #endif
            if let state, liveSurface == nil { liveSurface = IOSLiveRecordingSurface(state: state) }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

@main
struct MinutesiOSApp: App {
    @StateObject private var startup = IOSStartup()

    var body: some Scene {
        WindowGroup {
            if let state = startup.state, let surface = startup.liveSurface {
                IOSRootView(state: state).environmentObject(surface.captions)
            } else {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(startup.error ?? "The meeting database could not be opened.")
                } actions: {
                    Button("Retry") { startup.retry() }
                }
            }
        }
    }
}

private struct IOSRootView: View {
    @ObservedObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    private var processingNeedsScreen: Bool { state.isProcessing || state.isSummarizing || state.isFinalizingRecording }
    @State private var continuedProcessing: ContinuedProcessing?
    @State private var importing = false
    @State private var search = ""
    @State private var recorderPresented = false
    @State private var connectingAppleCalendar = false
    @State private var creatingFolder = false
    @State private var managingFolders = false
    @State private var editingFolder: MeetingFolder?
    @State private var deletingFolder: MeetingFolder?
    @State private var folderError: String?
    @State private var deletingMeeting: Meeting?
    @State private var movingMeeting: Meeting?
    @State private var showingTrash = false

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                if ProcessingAcceptance.enabled {
                    Section("Synthetic lock test · separate library") {
                        Text(state.statusMessage)
                        Text(state.prismMessage).font(.caption)
                        Button("Start silent synthetic processing") {
                            Task { await ProcessingAcceptance.run(state: state) }
                        }.disabled(state.isProcessing || state.isSummarizing)
                        Text("After tapping Start, lock the phone for one minute, then reopen Minutes. Personal recordings are not used.").font(.caption)
                    }
                }
                #endif
                Section {
                    NavigationLink { upcomingList } label: { homeShortcutLabel("Upcoming", symbol: "calendar", color: .blue) }
                    NavigationLink { IOSPeopleDirectory(state: state) } label: { homeShortcutLabel("People", symbol: "person.2.fill", color: .cyan) }
                }
                Section("On My iPhone") {
                    NavigationLink { meetingList(scope: .all) } label: {
                        folderLabel("All Meetings", count: state.meetings.count)
                    }
                    NavigationLink { meetingList(scope: .unfiled) } label: {
                        folderLabel("Unfiled", count: state.folderCount(nil))
                    }
                    .meetingFolderDropTarget(knownIDs: { Set(state.meetings.map(\.id)) },
                        move: { try state.moveMeetings($0, to: nil) }, onError: { folderError = $0.localizedDescription })
                    ForEach(state.folders) { folder in
                        NavigationLink { meetingList(scope: .folder(folder.id)) } label: {
                            folderLabel(folder.name, count: state.folderCount(folder.id))
                        }
                        .meetingFolderDropTarget(knownIDs: { Set(state.meetings.map(\.id)) },
                            move: { try state.moveMeetings($0, to: folder.id) }, onError: { folderError = $0.localizedDescription })
                        .contextMenu {
                            Button("Rename Folder", systemImage: "pencil") { editingFolder = folder }
                            Button("Delete Folder", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = folder }.tint(.red)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 110, for: .scrollContent)
            .onAppear { state.selectLibrary(.all) }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { settingsForm } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creatingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await state.organizeUnfiledMeetings() } } label: { Label("Organize Unfiled Meetings", systemImage: "folder.badge.gearshape") }
                        .disabled(state.isRecording || state.isProcessing || state.isOrganizingFolders || state.folders.isEmpty)
                }
            }
            .overlay(alignment: .bottom) { recordingFooter }
            .navigationDestination(isPresented: $recorderPresented) { IOSRecordingNote(state: state) }
        }
        // Primary tint keeps navigation monochrome; swipe actions set their own colours.
        .tint(.primary)
        .toggleStyle(MinutesToggleStyle())
        .sheet(isPresented: Binding(get: { !state.welcomeCompleted }, set: { _ in })) { WelcomeView(appState: state) }
        .sheet(isPresented: $showingTrash) {
            RecentlyDeletedView(load: { state.store.listMeetings(inTrash: true) }, restore: { try state.restoreMeeting($0) })
        }
        .confirmationDialog("Delete meeting?", isPresented: Binding(get: { deletingMeeting != nil }, set: { if !$0 { deletingMeeting = nil } }), titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                if let meeting = deletingMeeting {
                    do { try state.trashMeeting(meeting.id) } catch { folderError = error.localizedDescription }
                }
                deletingMeeting = nil
            }
        } message: { Text("You can restore this meeting and its recording from Recently Deleted in Settings.") }
        .confirmationDialog("Move to folder", isPresented: Binding(get: { movingMeeting != nil }, set: { if !$0 { movingMeeting = nil } }), titleVisibility: .visible) {
            Button("Unfiled") { if let meeting = movingMeeting { moveMeeting(meeting.id, to: nil) }; movingMeeting = nil }
            ForEach(state.folders) { folder in
                Button(folder.name) { if let meeting = movingMeeting { moveMeeting(meeting.id, to: folder.id) }; movingMeeting = nil }
            }
        }
        .sheet(isPresented: $creatingFolder) {
            MeetingFolderEditor(title: "New Folder") { try state.createFolder(name: $0, description: $1) }
        }
        .confirmationDialog("Delete folder?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let folder = deletingFolder {
                    do { try state.deleteFolder(id: folder.id) } catch { folderError = error.localizedDescription }
                }
                deletingFolder = nil
            }
        } message: { Text("Meetings are kept in Unfiled. Only the folder is removed.") }
        .sheet(isPresented: $managingFolders) { folderManager }
        .sheet(item: $editingFolder) { folder in
            MeetingFolderEditor(title: "Edit Folder", name: folder.name, description: folder.description) {
                try state.updateFolder(id: folder.id, name: $0, description: $1)
            }
        }
        .alert("Could not move meeting", isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })) {
            Button("OK") { folderError = nil }
        } message: { Text(folderError ?? "") }
        .onChange(of: processingNeedsScreen, initial: true) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy && scenePhase == .active
            if continuedProcessing == nil { continuedProcessing = ContinuedProcessing(state: state) }
            continuedProcessing?.busyChanged(busy)
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = processingNeedsScreen && phase == .active
            if phase == .active {
                state.syncLibraryNow()
                Task { await state.resumePendingSummaries() }
            }
            #if DEBUG
            ProcessingAcceptance.record("scene-\(phase)", state: state)
            #endif
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            #if DEBUG
            if ProcessingAcceptance.enabled { return }
            #endif
            await state.restoreCalendarConnections()
        }
        .onChange(of: state.statusMessage) { _, _ in
            #if DEBUG
            ProcessingAcceptance.record("status", state: state)
            #endif
        }
        .task { await state.restorePrismConnection() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                        let isTranscript = type?.conforms(to: .plainText) == true
                        _ = try await state.importMedia(from: url, isTranscript: isTranscript)
                    }
                    catch { state.statusMessage = "Import failed: \(error.localizedDescription)" }
                }
            case .failure(let error): state.statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private var filteredMeetings: [Meeting] {
        guard !search.isEmpty else { return state.libraryMeetings }
        return state.libraryMeetings.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.userNotes?.localizedCaseInsensitiveContains(search) ?? false) || state.store.listUtterances(meetingId: $0.id).contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }
    private var recordingFooter: some View {
        RecordingLaunchButton(isRecording: state.isRecording, duration: state.recordingDuration, style: .circle) { recorderPresented = true }
            .padding(.bottom, 12)
    }
    private func meetingList(scope: MeetingLibraryScope) -> some View {
        List {
            ForEach(MeetingDateGroup.sections(for: filteredMeetings)) { group in
            Section {
                ForEach(group.meetings) { meeting in
                    NavigationLink {
                        IOSMeetingDetail(state: state, meetingID: meeting.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.headline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day()).foregroundStyle(.primary)
                                Text(meeting.userNotes?.replacingOccurrences(of: "\n", with: " ") ?? state.store.listUtterances(meetingId: meeting.id).first?.text ?? "No additional text").foregroundStyle(.secondary).lineLimit(1)
                            }.font(.subheadline)
                            Label(state.folderName(for: meeting.id), systemImage: "folder").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onDrag { MeetingDragTransfer.provider(meetingID: meeting.id) } preview: {
                            Label(meeting.title, systemImage: "note.text").font(.body).lineLimit(2).padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }.tint(.red)
                        Button("Move", systemImage: "folder") { movingMeeting = meeting }.tint(.indigo)
                    }
                    .contextMenu {
                        Button("Delete Meeting", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }
                        Menu("Move to Folder", systemImage: "folder") {
                            MeetingFolderDestinations(folders: state.folders) { moveMeeting(meeting.id, to: $0) }
                        }
                    }
                }
            } header: { Text(group.title).textCase(nil).font(.title2.bold()).foregroundStyle(.primary) }
            }
        }
        // Plain rows (as in Voice Memos) slide cleanly when swiped; inset cards
        // swap a hard edge for a rounded one mid-gesture.
        .listStyle(.plain)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .navigationTitle(state.libraryTitle)
        .onAppear { state.selectLibrary(scope) }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .overlay { if filteredMeetings.isEmpty { ContentUnavailableView(search.isEmpty ? "No Meetings" : "No Results", systemImage: "note.text", description: Text(search.isEmpty ? "Record a meeting or import audio to begin." : "Try a different search.")) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Import Recording or Transcript", systemImage: "square.and.arrow.down") { importing = true }.disabled(state.isRecording || state.isProcessing) }

        }
        .overlay(alignment: .bottom) { recordingFooter }
    }
    private func homeShortcutLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 7))
        }
    }
    private func folderLabel(_ name: String, count: Int) -> some View {
        Label {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: { Image(systemName: "folder").foregroundStyle(.yellow) }
    }
    private var folderManager: some View {
        MeetingFolderManager(folders: state.folders, count: { state.folderCount($0) },
            autoFile: $state.autoFileMeetingsEnabled, canOrganize: !state.isRecording && !state.isProcessing,
            isOrganizing: state.isOrganizingFolders, organizationMessage: state.folderFilingMessage,
            onCreate: { try state.createFolder(name: $0, description: $1) },
            onUpdate: { try state.updateFolder(id: $0, name: $1, description: $2) },
            onDelete: { try state.deleteFolder(id: $0) },
            onOrganize: { Task { await state.organizeUnfiledMeetings() } })
    }
    private func moveMeeting(_ id: String, to folderID: String?) {
        do { try state.moveMeeting(id, to: folderID) }
        catch { folderError = error.localizedDescription }
    }
    private var upcomingList: some View {
        CalendarAgendaView(events: state.upcomingEvents, sourceName: state.calendarSource.rawValue,
            isConnected: state.calendarConnected, isRefreshing: state.googleRefreshing,
            isConnecting: state.googleConnecting || connectingAppleCalendar,
            statusMessage: state.calendarSource == .google ? state.googleMessage : state.calendarMessage,
            recordingUnavailableReason: calendarRecordingUnavailableReason, showsConnectionControls: false,
            onRefresh: { state.refreshCalendar() },
            onConnect: {
                connectingAppleCalendar = true
                Task { await state.connectCalendar(); connectingAppleCalendar = false }
            },
            onOpenSettings: {},
            onRecord: { event in Task { await record(event: event) } },
            notificationsEnabled: state.calendarNotificationsEnabled,
            onEnableNotifications: { Task { await state.enableCalendarNotifications() } })
            .navigationTitle("Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.refreshCalendar() } label: {
                        if state.googleRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                        .accessibilityLabel("Refresh calendar")
                        .disabled(!state.calendarConnected || state.googleRefreshing)
                }
            }
            .onAppear { state.refreshSpeechReadiness() }
    }
    private var calendarRecordingUnavailableReason: String? {
        if state.isRecording || state.isProcessing || state.isFinalizingRecording { return "Finish the current recording before starting another." }
        if state.isPreparingRecording || state.isStartingRecording { return "Checking recording setup…" }
        if state.isSettingUpSpeechModels { return "Speech models are being installed." }
        if !state.recordingModelsReady { return "Set up local speech models in Settings before recording." }
        return nil
    }
    private var settingsForm: some View {
                Form {
                    Section("Local speech") {
                        Text(state.speechModelStatus).font(.footnote)
                        Button(state.isSettingUpSpeechModels ? "Setting up models…" : "Set up speaker models") {
                            Task { await state.setupSpeechModels() }
                        }.disabled(state.isSettingUpSpeechModels || state.isProcessing)
                        Text("Setup downloads the trained speaker models once. Processing uses installed models and Apple on-device speech. Speaker names remain yours to confirm.").font(.footnote)
                    }
                    IOSLiveCaptionSetting()
                    Section("Meeting folders") {
                        Button("Recently Deleted", systemImage: "trash") { showingTrash = true }
                        NavigationLink {
                            AudioStorageView(load: { await state.audioStorageEntries() },
                                             compress: { await state.compactAudio(meetingIDs: $0) },
                                             delete: { state.deleteAudio(meetingIDs: $0) })
                                .navigationTitle("Storage")
                        } label: { Label("Storage", systemImage: "internaldrive") }
                        Toggle("Automatically file new meetings", isOn: $state.autoFileMeetingsEnabled)
                        Button("Edit folders") { managingFolders = true }
                        Button(state.isOrganizingFolders ? "Organizing…" : "Organize Unfiled Meetings") { Task { await state.organizeUnfiledMeetings() } }
                            .disabled(state.folders.isEmpty || state.isRecording || state.isProcessing || state.isOrganizingFolders)
                        if !state.folderFilingMessage.isEmpty { Text(state.folderFilingMessage).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Section("Calendars") {
                        Text(state.calendarSource == .apple ? state.calendarMessage : "Apple Calendar uses accounts configured on this iPhone.").font(.footnote).foregroundStyle(.secondary)
                        Button("Connect Apple Calendar") { Task { await state.connectCalendar() } }
                        if state.calendarNotificationsEnabled {
                            Label("Meeting reminders enabled", systemImage: "bell.badge").foregroundStyle(.secondary)
                        } else {
                            Button("Enable meeting reminders") { Task { await state.enableCalendarNotifications() } }
                        }
                    }
                    LibrarySyncSettings(appState: state)
                    googleSettings
                    prismSettings
                    summarySettings
                    Section("Permissions") {
                        Button("Allow microphone") { Task { _ = await state.permissionManager.requestMicrophoneAccess() } }
                    }
                    Section("Remembered voices") {
                        ForEach(state.voiceprints) { voiceprint in
                            HStack {
                                Text(state.store.getPerson(id: voiceprint.personId)?.displayName ?? "Remembered voice")
                                Spacer()
                                Button("Forget", role: .destructive) {
                                    do {
                                        try state.store.deleteVoiceprint(id: voiceprint.id)
                                        state.voiceprints = state.store.listVoiceprints()
                                    } catch { state.statusMessage = "Could not forget voice: \(error.localizedDescription)" }
                                }
                            }
                        }
                        if state.voiceprints.isEmpty { Text("No voices remembered.").foregroundStyle(.secondary) }
                    }
                    Section("Status") { Text(state.statusMessage).font(.footnote).textSelection(.enabled) }
                }.navigationTitle("Settings").onAppear { state.refreshSpeechReadiness() }
    }

    private var googleSettings: some View {
        Section("Google Calendar · Beta") {
            Text(state.googleMessage).font(.footnote).foregroundStyle(.secondary)
            if !state.googleConnected {
                Text("Google is still reviewing Minutes, so sign-in shows a warning first. Apple Calendar works without it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Connect Google") { Task { await state.connectGoogleCalendar() } }.disabled(state.googleConnecting)
            if state.googleConnected {
                Button("Refresh Calendar") { Task { await state.resumeGoogleCalendar() } }.disabled(state.googleConnecting)
            }
            GoogleCalendarPicker(appState: state)
            Button(state.googleConnecting ? "Cancel Google sign-in" : "Disconnect Google", role: .destructive) {
                Task { await state.disconnectGoogleCalendar() }
            }.disabled(!state.googleConnected && !state.googleConnecting)
            Text("Read-only access to calendars and meeting invitees.")
                .font(.footnote).foregroundStyle(.secondary)
            #if DEBUG
            DisclosureGroup("Advanced") {
                TextField("iOS public client ID", text: $state.googleIOSClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("The app’s Google registration is preconfigured. Change this only when using a different native OAuth client; tokens remain in Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #endif
        }
    }
    @ViewBuilder private var prismSettings: some View {
        ParachuteVaultSettings(appState: state)
        if !state.prismOutbox.isEmpty {
            Section("Earlier Prism deliveries") {
                ForEach(state.prismOutbox) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.store.getMeeting(id: item.meetingId)?.title ?? "Meeting")
                        Text("\(item.destinationVault) · \(item.status.rawValue.replacingOccurrences(of: "_", with: " "))").font(.caption).foregroundStyle(.secondary)
                        if item.status != .synced && item.status != .revoked {
                            Button("Cancel delivery", role: .destructive) { Task { await state.cancelPrismDelivery(id: item.id) } }.disabled(state.prismBusy)
                        }
                    }
                }
            }
        }
    }
    private var summarySettings: some View {
        Section("Meeting notes") {
            Toggle("Use Apple Intelligence", isOn: $state.summaryUsesAppleIntelligence)
            Picker("Summary template", selection: $state.summaryTemplate) {
                ForEach(SummaryTemplate.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            Text(FoundationModelsProvider.availability().message)
                .font(.footnote).foregroundStyle(.secondary)
            Text("When generation is unavailable, saved notes are clearly labeled as extracts from your transcript.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func record(event: CalendarMeetingEvent? = nil) async {
        recorderPresented = true
        guard await state.prepareRecording() else { return }
        state.startQuickMeeting(event: event)
    }
}
