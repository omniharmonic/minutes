#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import MinutesCore
import MinutesSummarize
import MinutesSpeakerID
import MinutesSpeech
import MinutesCalendar
import MinutesUI
import MinutesExport

@available(macOS 15.0, iOS 18.0, *)
public struct MainWindowView: View {
    @ObservedObject public var appState: AppState
    @State private var meetingTab = MeetingTab.notes
    @State private var transcriptFindRequest = 0
    @State private var notesFindRequest = 0
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var importing = false
    @State private var recorderPresented = false
    @State private var measuredSidebarWidth: CGFloat = 225
    @State private var measuredLibraryWidth: CGFloat = 280
    @State private var upcomingSelection: String?
    @State private var connectingAppleCalendar = false
    @State private var personSelection: String?
    @State private var confirmingReprocess = false
    @State private var reprocessMeetingID: String?
    @State private var creatingFolder = false
    @State private var deletingMeeting: Meeting?
    @State private var movingMeeting: Meeting?
    @State private var deletingFolder: MeetingFolder?
    @State private var editingFolder: MeetingFolder?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    public enum MeetingTab: String, CaseIterable, Identifiable {
        case notes = "Notes", transcript = "Transcript", speakers = "Speakers"
        public var id: String { rawValue }
    }
    public init(appState: AppState) { self.appState = appState }
    public var body: some View {
        NavigationSplitView {
            List {
                Section {
                    sidebarItem(.calendar, title: "Upcoming", symbol: "calendar")
                    sidebarItem(.voiceprintHub, title: "People", symbol: "person.2")
                }
                Section("On My Mac") {
                    librarySidebarItem(.all, title: "All Meetings", count: appState.meetings.count, destination: nil, allowsDrop: false)
                    librarySidebarItem(.unfiled, title: "Unfiled", count: appState.folderCount(nil), destination: nil)
                    ForEach(appState.folders) { folder in
                        librarySidebarItem(.folder(folder.id), title: folder.name, count: appState.folderCount(folder.id), destination: folder.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                            }
                            .help(folder.description.isEmpty ? folder.name : folder.description)
                            .contextMenu {
                                Button("Rename Folder", systemImage: "pencil") { editingFolder = folder }
                                Button("Delete Folder", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 8)
            .background {
                NotesSidebarSurface()
                    .padding(.leading, 8).padding(.vertical, 8)
                    .ignoresSafeArea(edges: .top)
            }
            .background(MinutesTheme.bg)
            .navigationTitle("Minutes")
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button { creatingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        .help("New folder")
                    Button { Task { await appState.organizeUnfiledMeetings() } } label: { Label("Organize Unfiled Meetings", systemImage: "folder.badge.gearshape") }
                        .help("Organize unfiled meetings on device")
                        .disabled(recordingBusy || appState.isOrganizingFolders || appState.folders.isEmpty)
                }
            }
            .navigationSplitViewColumnWidth(min: 225, ideal: 225, max: 320)
            .background { GeometryReader { geometry in Color.clear.preference(key: SidebarWidthPreference.self, value: geometry.size.width) } }
        } content: {
            Group {
                if appState.selectedSection == .calendar { upcomingList }
                else if appState.selectedSection == .voiceprintHub { peopleList }
                else { meetingList }
            }
            .background { GeometryReader { geometry in Color.clear.preference(key: LibraryWidthPreference.self, value: geometry.size.width) } }
        } detail: {
            detail
                .toolbar {
                    if #available(macOS 26.0, iOS 26.0, *) {
                        documentToolbar.sharedBackgroundVisibility(.hidden)
                    } else { documentToolbar }
                }
                .toolbarRole(.editor)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if appState.isRecording {
                        if !recorderPresented || meetingTab != .notes || appState.currentMeeting?.id != appState.activeRecordingMeetingID { activity }
                    } else if appState.isProcessing || appState.isSummarizing || appState.isStartingRecording || appState.isFinalizingRecording || appState.isPreparingRecording || appState.isSettingUpSpeechModels { activity }
                    else if appState.statusMessage != "Ready" { message }
                }
        }
        .navigationSplitViewStyle(.balanced)

        .onPreferenceChange(SidebarWidthPreference.self) { measuredSidebarWidth = $0 }
        .onPreferenceChange(LibraryWidthPreference.self) { measuredLibraryWidth = $0 }
        .overlay(alignment: .leading) {
            GeometryReader { _ in
                Rectangle().fill(MinutesTheme.bg).frame(width: 1).offset(x: measuredSidebarWidth)
                Rectangle().fill(MinutesTheme.document).frame(width: 1).offset(x: measuredSidebarWidth + measuredLibraryWidth + 1)
            }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        }
        .tint(.yellow)
        .toggleStyle(MinutesToggleStyle())
        .confirmationDialog("Delete meeting?", isPresented: Binding(get: { deletingMeeting != nil }, set: { if !$0 { deletingMeeting = nil } }), titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                if let meeting = deletingMeeting { perform("delete meeting") { try appState.trashMeeting(meeting.id) } }
                deletingMeeting = nil
            }
        } message: { Text("You can restore this meeting and its recording from Recently Deleted in Settings.") }
        .confirmationDialog("Move to folder", isPresented: Binding(get: { movingMeeting != nil }, set: { if !$0 { movingMeeting = nil } }), titleVisibility: .visible) {
            Button("Unfiled") { if let meeting = movingMeeting { moveMeeting(meeting.id, to: nil) }; movingMeeting = nil }
            ForEach(appState.folders) { folder in
                Button(folder.name) { if let meeting = movingMeeting { moveMeeting(meeting.id, to: folder.id) }; movingMeeting = nil }
            }
        }
        .sheet(isPresented: $creatingFolder) {
            MeetingFolderEditor(title: "New Folder") { try appState.createFolder(name: $0, description: $1) }
        }
        .confirmationDialog("Delete folder?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let folder = deletingFolder { perform("delete folder") { try appState.deleteFolder(id: folder.id) } }
                deletingFolder = nil
            }
        } message: { Text("Meetings are kept in Unfiled. Only the folder is removed.") }
        .sheet(item: $editingFolder) { folder in
            MeetingFolderEditor(title: "Edit Folder", name: folder.name, description: folder.description) {
                try appState.updateFolder(id: folder.id, name: $0, description: $1)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MinutesFocusLibrarySearch"))) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MinutesFindInTranscript"))) { _ in
            guard appState.currentMeeting != nil else { return }
            findInTranscript()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MinutesImportAudio"))) { _ in importing = true }
        .meetingMarkdownExporter(state: appState)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .plainText]) { result in
            switch result {
            case .success(let url): Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                    _ = try await appState.importMedia(from: url, isTranscript: type?.conforms(to: .plainText) == true)
                    appState.selectedSection = .meetings
                } catch { appState.statusMessage = "Import failed: \(error.localizedDescription)" }
            }
            case .failure(let error): appState.statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .onChange(of: appState.isRecording) { _, recording in
            if recording { showRecordingWorkspace() }
        }
        .onChange(of: appState.activeRecordingMeetingID) { previous, current in
            if previous != nil, current == nil { recorderPresented = false }
        }
        .onChange(of: appState.selectedSection) { _, section in
            if section == .liveIngestion { showRecordingWorkspace() }
            if section == .settings || section == .onboarding {
                #if os(macOS)
                openSettings()
                #endif
                appState.selectedSection = .meetings
            }
        }
        .confirmationDialog("Transcribe this recording again?", isPresented: $confirmingReprocess, titleVisibility: .visible) {
            Button("Transcribe Again", role: .destructive) {
                guard appState.currentMeeting?.id == reprocessMeetingID else { return }
                Task { await appState.processCurrentMeeting() }
            }
            Button("Cancel", role: .cancel) { reprocessMeetingID = nil }
        } message: {
            Text("This reprocesses the saved audio and updates its transcript, speakers and automatic summary. Review any transcript edits and speaker choices afterward. Your notes are kept.")
        }
        .alert(item: $appState.calendarPrompt) { event in
            Alert(title: Text("Record \(event.title)?"), message: Text("Minutes will record your selected audio source."),
                  primaryButton: .default(Text("Record")) { recorderPresented = true; appState.selectedSection = .meetings; Task { if await appState.prepareRecording() { appState.startQuickMeeting(event: event) } } },
                  secondaryButton: .cancel(Text("Not now")) { appState.dismissCalendarPrompt(eventID: event.id) })
        }
    }
    private func sidebarItem(_ section: NavigationSection, title: String, symbol: String, count: Int? = nil) -> some View {
        let selected = appState.selectedSection == section
        return Button { appState.selectedSection = section } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
                if let count { Text(count, format: .number).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .foregroundStyle(selected ? Color.yellow : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func librarySidebarItem(_ scope: MeetingLibraryScope, title: String, count: Int, destination: String?, allowsDrop: Bool = true) -> some View {
        let selected = appState.selectedSection == .meetings && appState.libraryScope == scope
        return Button { appState.selectLibrary(scope) } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(.yellow).frame(width: 20)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text(count, format: .number).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .meetingFolderDropTarget(enabled: allowsDrop, knownIDs: { Set(appState.meetings.map(\.id)) },
            move: { try appState.moveMeetings($0, to: destination) },
            onError: { appState.statusMessage = "Could not move meeting: \($0.localizedDescription)" })
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var folderManager: some View {
        MeetingFolderManager(folders: appState.folders, count: { appState.folderCount($0) },
            autoFile: $appState.autoFileMeetingsEnabled, canOrganize: !appState.isRecording && !appState.isProcessing,
            isOrganizing: appState.isOrganizingFolders, organizationMessage: appState.folderFilingMessage,
            onCreate: { try appState.createFolder(name: $0, description: $1) },
            onUpdate: { try appState.updateFolder(id: $0, name: $1, description: $2) },
            onDelete: { try appState.deleteFolder(id: $0) },
            onOrganize: { Task { await appState.organizeUnfiledMeetings() } })
    }
    private func moveMeeting(_ meetingID: String, to folderID: String?) {
        perform("move meeting") { try appState.moveMeeting(meetingID, to: folderID) }
    }
    @ToolbarContentBuilder private var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if appState.currentMeeting != nil && appState.selectedSection == .meetings {
                HStack(spacing: 8) {
                    meetingViewButton(.notes, symbol: "note.text")
                    meetingViewButton(.transcript, symbol: "text.alignleft")
                    meetingViewButton(.speakers, symbol: "person.2")
                }
                .padding(.horizontal, 6).frame(height: 36).fixedSize(horizontal: true, vertical: false)
                .minutesControlGlass(in: Capsule())
                .accessibilityElement(children: .contain)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 10) {
                // Search comes first so it sits in the same place in every section.
                searchField
                if appState.selectedSection == .calendar {
                    Button { appState.refreshCalendar() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 36).minutesControlGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain).disabled(!appState.calendarConnected || appState.googleRefreshing)
                    .help("Refresh calendar").accessibilityLabel("Refresh calendar")
                }
                if appState.selectedSection == .meetings, let share = appState.currentShareFile {
                    ShareLink(item: share, preview: SharePreview(appState.currentMeeting?.title ?? "Meeting")) {
                        // The glyph's box sits low in its bounds; lift it to the optical centre.
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                            .offset(y: -1.5)
                            .frame(width: 36, height: 36).contentShape(Circle())
                            .minutesControlGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain).help("Share meeting").accessibilityLabel("Share meeting")
                }
                if appState.selectedSection == .meetings, let meeting = appState.currentMeeting {
                    Menu { meetingActions(meeting) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Circle())
                            .minutesControlGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Meeting actions").accessibilityLabel("Meeting actions")
                }
            }
            .fixedSize()
        }
    }

    /// A capsule like the iPhone's search bar.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            TextField(appState.selectedSection == .calendar ? "Search events" : (appState.selectedSection == .voiceprintHub ? "Search people" : "Search meetings"), text: $search)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($searchFocused).accessibilityLabel("Search")
                .onExitCommand { search = ""; searchFocused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(width: 260, height: 36)
        .minutesControlGlass(in: Capsule(), interactive: true)
        .help("Search (⌥⌘F)")
    }

    @ViewBuilder private func meetingActions(_ meeting: Meeting) -> some View {
        Section("Export") {
            Button("Export Markdown…", systemImage: "doc.badge.arrow.up") { appState.prepareMarkdownExport() }
            Button(appState.parachuteVault.map { "Save to “\($0.vault)”" } ?? "Save to Parachute Vault…", systemImage: "tray.and.arrow.up") {
                if appState.parachuteVault == nil { openSettings() }
                else { Task { _ = await appState.exportCurrentMeeting(target: "parachute") } }
            }
        }
        if appState.canContinueRecording(meeting) {
            Section {
                Button("Continue Recording", systemImage: "record.circle") {
                    recorderPresented = true
                    Task { await appState.continueRecording(meetingID: meeting.id) }
                }
            }
        }
        Section {
            if !appState.currentUtterances.isEmpty {
                Button("Search Transcript", systemImage: "magnifyingglass") { findInTranscript() }
            }
            if meeting.audioPath != nil && meeting.platform != "transcript_import" {
                Button("Regenerate from Recording…", systemImage: "arrow.trianglehead.2.clockwise") { reprocessMeetingID = meeting.id; confirmingReprocess = true }
                    .disabled(recordingBusy)
            }
            Menu("Move to Folder", systemImage: "folder") {
                MeetingFolderDestinations(folders: appState.folders) { moveMeeting(meeting.id, to: $0) }
            }
        }
        Section {
            Button("Delete Meeting", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }
        }
    }

    private func meetingViewButton(_ tab: MeetingTab, symbol: String) -> some View {
        Button { meetingTab = tab } label: {
            Label(tab.rawValue, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 16))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
                .foregroundStyle(meetingTab == tab ? Color.primary : Color.secondary)
        }
        .controlSize(.regular)
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tab.rawValue))
        .accessibilityIdentifier("meeting-view-\(tab.rawValue.lowercased())")
        .accessibilityAddTraits(meetingTab == tab ? [.isButton, .isSelected] : [.isButton])
        .help(tab.rawValue)
        .id(tab)
    }
    private var filteredMeetings: [Meeting] {
        guard !search.isEmpty else { return appState.libraryMeetings }
        return appState.libraryMeetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(search) ||
            (meeting.userNotes?.localizedCaseInsensitiveContains(search) ?? false) ||
            appState.store.listUtterances(meetingId: meeting.id).contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }
    private var meetingList: some View {
        VStack(spacing: 0) {
            libraryHeader.background(MinutesTheme.bg).zIndex(1)
            ScrollViewReader { _ in
                // Native list selection (clicks, arrow keys, swipes). Rows offer
                // their drag item through itemProvider, which works with selection;
                // a tap gesture plus onDrag on each row dropped clicks.
                List(selection: Binding(get: { appState.selectedMeetingId }, set: { appState.selectedMeetingId = $0 })) {
                    ForEach(MeetingDateGroup.sections(for: filteredMeetings)) { group in
                        Section {
                            ForEach(group.meetings) { meeting in meetingRow(meeting) }
                        } header: {
                            Text(group.title).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.leading, 12)
                        }
                    }
                    Color.clear.frame(height: 72).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(MinutesTheme.bg)
        .navigationTitle(appState.libraryTitle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        .overlay {
            if filteredMeetings.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Meetings" : "No Results", systemImage: "note.text", description: Text(search.isEmpty ? "Record a meeting or import audio to begin." : "Try a different search."))
            }
        }
        .overlay(alignment: .bottom) {
            if !recorderPresented {
                RecordingLaunchButton(isRecording: appState.isRecording, duration: appState.recordingDuration) { showRecordingWorkspace() }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 18)
            }
        }
        .onChange(of: appState.selectedMeetingId) { _, id in
            appState.selectMeeting(id: id); meetingTab = .notes
            if appState.activeRecordingMeetingID != id { recorderPresented = false }
        }
    }
    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                Text(preview(meeting)).foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size: 12))
            Label(appState.folderName(for: meeting.id), systemImage: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
            if meeting.status == "failed" { Text("Needs attention").font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.vertical, 5)
        .contentShape(Rectangle())
        .tag(meeting.id as String?)  // must match the String? selection exactly
        .itemProvider { MeetingDragTransfer.provider(meetingID: meeting.id) }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 12))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }.tint(.red)
            Button("Move", systemImage: "folder") { movingMeeting = meeting }.tint(.indigo)
        }
        .contextMenu {
            Button("Delete Meeting", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }
            Menu("Move to Folder", systemImage: "folder") {
                MeetingFolderDestinations(folders: appState.folders) { moveMeeting(meeting.id, to: $0) }
            }
        }
    }
    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.libraryTitle).font(.system(size: 13, weight: .semibold))
                Text("\(filteredMeetings.count) meetings").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Import Audio or Transcript…") { importing = true }

            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16))
                    .frame(width: 32, height: 32).minutesControlGlass(in: Circle(), interactive: true)
            }.buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Library actions")
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.top, 10).padding(.bottom, 8)
    }
    private func preview(_ meeting: Meeting) -> String {
        if let notes = meeting.userNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return notes.replacingOccurrences(of: "\n", with: " ") }
        return appState.store.firstUtteranceText(meetingId: meeting.id) ?? "No additional text"
    }
    private var peopleList: some View {
        List(selection: $personSelection) {
            ForEach(appState.store.listPeople().filter { person in
                search.isEmpty || person.displayName.localizedCaseInsensitiveContains(search) || person.emails.contains { $0.localizedCaseInsensitiveContains(search) }
            }) { person in
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName).font(.headline)
                    if let email = person.emails.first { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.vertical, 7).tag(person.id)
            }
        }.listStyle(.inset).navigationTitle("People")
            .navigationSplitViewColumnWidth(min: 220, ideal: 275)
    }
    private var upcomingList: some View {
        VStack(spacing: 0) {
        CalendarAgendaView(events: filteredCalendarEvents, sourceName: appState.calendarSource.rawValue,
            isConnected: appState.calendarConnected, isRefreshing: appState.googleRefreshing,
            isConnecting: appState.googleConnecting || connectingAppleCalendar,
            statusMessage: appState.calendarSource == .google ? appState.googleMessage : appState.calendarMessage,
            recordingUnavailableReason: calendarRecordingUnavailableReason, compact: true,
            selectedEventID: upcomingSelection, showsConnectionControls: false, onRefresh: { appState.refreshCalendar() },
            onConnect: {
                connectingAppleCalendar = true
                Task { await appState.connectCalendar(); connectingAppleCalendar = false }
            },
            onOpenSettings: { openSettings() }, onRecord: recordCalendarEvent,
            onSelect: { upcomingSelection = $0.id },
            notificationsEnabled: appState.calendarNotificationsEnabled,
            onEnableNotifications: { Task { await appState.enableCalendarNotifications() } })
            .navigationTitle("Upcoming").navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .onAppear { appState.refreshSpeechReadiness() }
        }
    }
    private var filteredCalendarEvents: [CalendarMeetingEvent] {
        guard !search.isEmpty else { return appState.upcomingEvents }
        return appState.upcomingEvents.filter { event in
            event.title.localizedCaseInsensitiveContains(search) || event.attendees.contains {
                $0.displayName.localizedCaseInsensitiveContains(search) || ($0.email?.localizedCaseInsensitiveContains(search) == true)
            }
        }
    }
    private var calendarRecordingUnavailableReason: String? {
        if recordingBusy { return "Finish the current recording before starting another." }
        if appState.isPreparingRecording { return "Checking recording setup…" }
        if appState.isSettingUpSpeechModels { return "Speech models are being installed." }
        if !appState.recordingModelsReady { return "Set up local speech models in Settings before recording." }
        return nil
    }
    private func recordCalendarEvent(_ event: CalendarMeetingEvent) {
        appState.selectedSection = .meetings; recorderPresented = true
        Task { if await appState.prepareRecording() { appState.startQuickMeeting(event: event) } }
    }
    @ViewBuilder private var detail: some View {
        if recorderPresented && (!appState.isRecording || appState.currentMeeting?.id != appState.activeRecordingMeetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button("Close Recording Setup", systemImage: "xmark") { recorderPresented = false }
                            .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 32, height: 32).minutesControlGlass(in: Circle(), interactive: true)
                            .disabled(appState.isPreparingRecording || appState.isStartingRecording || appState.isProcessing)
                    }
                    recordingWorkspace
                }.padding(32).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
            }
                .background(MinutesTheme.document)
        } else if appState.selectedSection == .calendar {
            if let event = appState.upcomingEvents.first(where: { $0.id == upcomingSelection }) {
                ScrollView {
                    CalendarEventDetailView(event: event, sourceName: appState.calendarSource.rawValue,
                        recordingUnavailableReason: calendarRecordingUnavailableReason, onRecord: { recordCalendarEvent(event) })
                        .padding(32).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
                }.background(MinutesTheme.document)
            } else { ContentUnavailableView("Select a Meeting", systemImage: "calendar") }
        } else if appState.selectedSection == .voiceprintHub {
            VoiceprintHubView(store: appState.store, voiceprints: appState.voiceprints,
                people: appState.store.listPeople(), selection: $personSelection, showsList: false,
                onOpenMeeting: { meeting in
                    appState.selectedSection = .meetings
                    appState.selectedMeetingId = meeting.id
                    appState.selectMeeting(id: meeting.id)
                    meetingTab = .notes
                }, playbackAllowed: !appState.isRecording && !appState.isStartingRecording && !appState.isFinalizingRecording)
        } else if let meeting = appState.currentMeeting, meetingTab == .transcript {
            VStack(spacing: 0) {
                meetingHeading(meeting)
                    .padding(.horizontal, 24).padding(.top, 12)
                    .frame(maxWidth: 920).frame(maxWidth: .infinity)
                meetingContent(meeting)
            }.id(meeting.id).background(MinutesTheme.document)
        } else if let meeting = appState.currentMeeting {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    meetingHeading(meeting)
                    if recorderPresented { recordingWorkspace.padding(.vertical, 8) }
                    meetingContent(meeting)
                }.id(meeting.id).padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 60)
                    .frame(maxWidth: 1180).frame(maxWidth: .infinity, alignment: .center)
            }.background(MinutesTheme.document)
        } else {
            ContentUnavailableView { Label("No Meeting Selected", systemImage: "note.text") }
                description: { Text("Choose a meeting, or start a new recording.") }
        }
    }
    private func meetingHeading(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                    Text(meeting.startedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    TextField("Meeting title", text: Binding(get: { appState.currentMeeting?.title ?? meeting.title }, set: { title in
                        perform("save title") {
                            guard var latest = appState.store.getMeeting(id: meeting.id) else { return }
                            latest.title = title; try appState.store.saveMeeting(latest)
                            appState.currentMeeting = latest
                            if let index = appState.meetings.firstIndex(where: { $0.id == latest.id }) { appState.meetings[index] = latest }
                        }
                    })).textFieldStyle(.plain).font(.system(size: 18, weight: .bold)).accessibilityLabel("Meeting title")
        }
    }
    private var recordingWorkspace: some View {
        RecordingWorkspaceView(isRecording: appState.isRecording,
            isBusy: appState.isStartingRecording || appState.isFinalizingRecording || appState.isProcessing || appState.isPreparingRecording,
            busyMessage: appState.isSummarizing ? "Preparing Meeting Notes…" : appState.isProcessing ? "Processing Saved Audio…" : (appState.isFinalizingRecording ? "Finalizing Recording…" : (appState.isStartingRecording ? "Starting Recording…" : "Checking Recording Permissions…")),
            canStart: appState.canStartRecording, modelsReady: appState.recordingModelsReady,
            isInstalling: appState.isSettingUpSpeechModels, readinessMessage: appState.speechModelStatus,
            statusMessage: appState.statusMessage, routeNotice: appState.recordingRouteNotice, meter: appState.recordingMeter,
            source: Binding(get: { appState.displayedCaptureMode.rawValue }, set: { if let source = AppState.CaptureMode(rawValue: $0) { appState.captureMode = source } }),
            sources: AppState.CaptureMode.allCases.map(\.rawValue), includesMicrophone: appState.displayedCaptureMode.includesMicrophone,
            onInstall: { Task { await appState.setupSpeechModels() } },
            onStart: { Task { if await appState.prepareRecording() { appState.startQuickMeeting() } } },
            onStop: { Task { await appState.stopAndProcessMeeting(); recorderPresented = false } },
            moments: appState.recordingBookmarks,
            onMarkMoment: { appState.markRecordingMoment() },
            onRenameMoment: { appState.renameBookmark($0, to: $1) },
            onRemoveMoment: { appState.deleteBookmark($0) })
            .onAppear { appState.refreshSpeechReadiness() }
    }
    private func showRecordingWorkspace() {
        appState.selectedSection = .meetings; recorderPresented = true; meetingTab = .notes
        if let id = appState.activeRecordingMeetingID { appState.selectedMeetingId = id; appState.selectMeeting(id: id) }
    }
    private var recordingBusy: Bool { appState.isRecording || appState.isProcessing || appState.isStartingRecording || appState.isFinalizingRecording }
    private var statusTitle: String {
        if appState.isRecording { return "Recording" }
        if appState.isFinalizingRecording { return "Saving Recording" }
        if appState.isStartingRecording || appState.isPreparingRecording { return "Preparing Recording" }
        if appState.isSummarizing { return "Preparing Meeting Notes" }
        if appState.isProcessing { return "Processing Recording" }
        if appState.isSettingUpSpeechModels { return "Installing Speech Models" }
        return "Meeting Status"
    }
    private var statusSummary: String {
        appState.isSettingUpSpeechModels ? appState.speechModelStatus : appState.statusMessage
    }
    @ViewBuilder private var activity: some View {
        if appState.isRecording {
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Recording").font(.callout.weight(.medium))
                Text(Duration.seconds(appState.recordingDuration).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { showRecordingWorkspace() } label: {
                    Label("Show Recording", systemImage: "waveform").font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain).accessibilityLabel("Show active recording")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .minutesControlGlass(in: Capsule()).padding(.horizontal, 20).padding(.vertical, 12)
        } else { statusSurface(isActive: true) }
    }
    @ViewBuilder private var message: some View {
        if appState.statusMessage.hasPrefix("On-device AI draft saved") ||
           appState.statusMessage.hasPrefix("Recording and on-device AI draft saved") ||
           appState.statusMessage.hasPrefix("Audio imported and processed:") ||
           appState.statusMessage.hasPrefix("Exported meeting") {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(appState.statusMessage).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
                Button { appState.statusMessage = "Ready" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .minutesControlGlass(in: Capsule())
            .padding(.horizontal, 20).padding(.vertical, 12)
            .task(id: appState.statusMessage) {
                let savedMessage = appState.statusMessage
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, appState.statusMessage == savedMessage else { return }
                appState.statusMessage = "Ready"
            }
        } else { statusSurface(isActive: false) }
    }
    private func statusSurface(isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if isActive {
                    if appState.isRecording { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                    else { ProgressView().controlSize(.small) }
                } else { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                Text(statusTitle).font(.headline)
                Spacer(minLength: 8)
                if appState.isRecording {
                    Text(Duration.seconds(appState.recordingDuration).formatted(.time(pattern: .minuteSecond)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { Task { await appState.stopAndProcessMeeting(); recorderPresented = false } }
                        .controlSize(.regular)
                } else if !isActive {
                    Button { appState.statusMessage = "Ready" } label: {
                        Image(systemName: "xmark").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss message").help("Dismiss message")
                }
            }
            // Bounded on purpose: this card sits in a bottom safe-area inset, so an
            // unbounded message height raised the window's minimum size past the
            // screen and pushed the toolbar off the top ("zoomed" window).
            Text(statusSummary).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1...5).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(statusSummary)
            if appState.isSettingUpSpeechModels && appState.statusMessage != "Ready"
                && appState.statusMessage != statusSummary {
                Text(appState.statusMessage).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1...3).truncationMode(.tail)
                    .help(appState.statusMessage)
            }
        }
        .padding(16)
        .minutesControlGlass(in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
    }
    /// Searches inside the transcript on the meeting page; the Transcript tab keeps its own field.
    private func findInTranscript() {
        appState.selectedSection = .meetings
        if meetingTab == .notes { notesFindRequest += 1; return }
        meetingTab = .transcript
        transcriptFindRequest += 1
    }
    @ViewBuilder private func meetingContent(_ meeting: Meeting) -> some View {
        switch meetingTab {
        case .notes:
            if meeting.calendarEventId == nil && meeting.platform != "transcript_import" && !recordingBusy {
                CalendarLinkButton(load: { await appState.calendarEventsOverlapping(meeting) },
                                   link: { appState.linkCalendarEvent($0, toMeeting: meeting.id) })
            }
            NotesView(meeting: meeting, summary: appState.currentSummary, utterances: appState.currentUtterances,
                      attendees: appState.currentAttendees, bookmarks: appState.currentBookmarks,
                onSaveNotes: { text in perform("save notes") { var m = appState.store.getMeeting(id: meeting.id) ?? meeting; m.userNotes = text; try appState.store.saveMeeting(m); appState.selectMeeting(id: m.id); if let index = appState.meetings.firstIndex(where: { $0.id == m.id }) { appState.meetings[index] = m } } },
                onSaveBookmark: { bookmark in perform("save bookmark") { try appState.store.saveBookmark(bookmark); appState.currentBookmarks = appState.store.listBookmarks(meetingId: meeting.id) } },
                onDeleteBookmark: { id in perform("delete bookmark") { try appState.store.deleteBookmark(id: id); appState.currentBookmarks = appState.store.listBookmarks(meetingId: meeting.id) } },
                onGenerateSummary: { Task { await appState.generateCurrentSummary() } },
                onExportMarkdown: { appState.prepareMarkdownExport() },
                onExportParachute: { Task { _ = await appState.exportCurrentMeeting(target: "parachute") } },
                onSaveSummary: { markdown in perform("save summary") { if var summary = appState.currentSummary { summary.markdown = markdown; try appState.store.saveSummary(summary); appState.currentSummary = summary } } }, isSummarizing: appState.isSummarizing,
                playbackAllowed: !appState.isRecording && !appState.isStartingRecording && !appState.isFinalizingRecording,
                usesAppleIntelligence: appState.summaryUsesAppleIntelligence,
                onEnableAppleSummary: { appState.summaryUsesAppleIntelligence = true; Task { await appState.generateCurrentSummary() } },
                onFindTranscript: { meetingTab = .transcript; transcriptFindRequest += 1 },
                onRegenerateRecording: { reprocessMeetingID = meeting.id; confirmingReprocess = true },
                isProcessingRecording: appState.isProcessing || recordingBusy,
                onRenameBookmark: { appState.renameBookmark($0, to: $1) },
                findRequest: notesFindRequest)
        case .transcript:
            TranscriptView(utterances: appState.currentUtterances, availableSpeakers: appState.currentClusters.map(\.label), clusters: appState.currentClusters, timestampsAvailable: meeting.platform != "transcript_import", findRequest: transcriptFindRequest,
                onSeek: { time in perform("play recording") {
                    guard !appState.isRecording && !appState.isStartingRecording && !appState.isFinalizingRecording else { return }
                    guard let path = meeting.audioPath, meeting.platform != "transcript_import" else { return }
                    try AudioPlaybackService.shared.loadAudio(path: path)
                    AudioPlaybackService.shared.play(from: time)
                } },
                onUtteranceEdited: { utterance in perform("save transcript") { try appState.store.saveUtterances([utterance]); appState.currentUtterances = TranscriptSpeakerLabels.readableUtterances(appState.store.listUtterances(meetingId: meeting.id), clusters: appState.currentClusters) } },
                onSpeakerReassigned: { id, name in perform("assign speaker") { var utterances = appState.currentUtterances; if let i = utterances.firstIndex(where: { $0.id == id }) { utterances[i].speakerName = name; try appState.store.saveUtterances([utterances[i]]); appState.currentUtterances = utterances } } },
                onExportParachute: { Task { _ = await appState.exportCurrentMeeting(target: "parachute") } },
                onExportMarkdown: { appState.prepareMarkdownExport() })
        case .speakers:
            ReviewSpeakersView(meeting: meeting, clusters: appState.currentClusters, attendees: appState.currentAttendees, utterances: appState.currentUtterances, voiceprints: appState.voiceprints,
                onAssign: { id, person in perform("assign speaker") { var clusters = appState.currentClusters; if let i = clusters.firstIndex(where: { $0.id == id }) { clusters[i].label = person.displayName; clusters[i].personId = person.id; clusters[i].assignment = "user"; try appState.store.withTransaction { try appState.store.savePerson(person); try appState.store.saveSpeakerClusters(clusters) }; appState.currentClusters = clusters } } },
                onLockAndEnroll: { confirmed in perform("remember voice") {
                    try appState.store.withImmediateTransaction {
                        for cluster in confirmed {
                            guard let personID = cluster.personId else { throw VoiceEnrollmentError.missingPerson }
                            try VoiceEnrollment.remember(store: appState.store, personID: personID,
                                meetingID: meeting.id, clusterID: cluster.id, expected: cluster)
                        }
                    }
                    appState.voiceprints = appState.store.listVoiceprints()
                    appState.currentClusters = appState.store.listSpeakerClusters(meetingId: meeting.id)
                    appState.currentUtterances = appState.store.listUtterances(meetingId: meeting.id)
                } },
                onReassignUtterances: { id, name in perform("update transcript speakers") { var utterances = appState.currentUtterances; for i in utterances.indices where utterances[i].clusterId == id { utterances[i].speakerName = name }; try appState.store.saveUtterances(utterances); appState.currentUtterances = utterances } },
                onKeepUnknown: { id in perform("keep speaker unknown") {
                    var clusters = appState.currentClusters
                    guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
                    clusters[index].label = "Unknown speaker"
                    clusters[index].personId = nil
                    clusters[index].assignment = "unknown"
                    clusters[index].confidence = 0
                    var utterances = appState.currentUtterances
                    for i in utterances.indices where utterances[i].clusterId == id { utterances[i].speakerName = "Unknown speaker" }
                    try appState.store.withTransaction {
                        try appState.store.saveSpeakerClusters(clusters)
                        try appState.store.saveUtterances(utterances)
                    }
                    appState.currentClusters = clusters
                    appState.currentUtterances = utterances
                } }, availablePeople: appState.store.listPeople(),
                playbackAllowed: !appState.isRecording && !appState.isStartingRecording && !appState.isFinalizingRecording)
        }
    }
    private func perform(_ action: String, _ operation: () throws -> Void) {
        do { try operation() } catch { appState.statusMessage = "Could not \(action): \(error.localizedDescription)" }
    }
}
private struct SidebarWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 225
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct LibraryWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct NotesSidebarSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        if reduceTransparency {
            shape.fill(MinutesTheme.card).overlay { shape.strokeBorder(MinutesTheme.border) }
        } else if #available(macOS 26.0, iOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular.tint(MinutesTheme.document.opacity(0.5)), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.14)) }
        } else {
            shape.fill(.regularMaterial).overlay { shape.strokeBorder(MinutesTheme.border) }
        }
    }
}

#endif
