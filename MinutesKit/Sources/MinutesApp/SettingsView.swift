#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import MinutesCore
import MinutesUI
import MinutesSummarize

@available(macOS 15.0, iOS 18.0, *)
public struct SettingsView: View {
    @ObservedObject public var appState: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openURL) private var openURL
    @State private var choosingMarkdownFolder = false
    @State private var showingTrash = false
    @State private var folderError: String?

    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            calendar.tabItem { Label("Calendar", systemImage: "calendar") }
            connections.tabItem { Label("Connections", systemImage: "link") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            AudioStorageView(load: { await appState.audioStorageEntries() },
                             compress: { await appState.compactAudio(meetingIDs: $0) },
                             delete: { appState.deleteAudio(meetingIDs: $0) })
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .sheet(isPresented: $showingTrash) { RecentlyDeletedView(load: { appState.store.listMeetings(inTrash: true) }, restore: { try appState.restoreMeeting($0) }) }
        .controlSize(.regular)
        .onAppear {
            appState.refreshSpeechReadiness()
            permissions.checkAllPermissions()
        }
        .fileImporter(isPresented: $choosingMarkdownFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                appState.markdownDirectory = url.path
                folderError = nil
            case .failure(let error): folderError = error.localizedDescription
            }
        }
    }

    private var general: some View {
        Form {
            #if os(macOS)
            Section("Recording") {
                Picker("Audio source", selection: $appState.captureMode) {
                    ForEach(AppState.CaptureMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .disabled(appState.isRecording || appState.isStartingRecording)
            }
            #endif
            Section("Meeting folders") {
                Button("Recently Deleted", systemImage: "trash") { showingTrash = true }
                Toggle("Automatically file new meetings", isOn: $appState.autoFileMeetingsEnabled)
                Text("On-device matching files confident matches. Manual folder choices are kept. Use Organize in the sidebar to file existing unfiled meetings.").font(.caption).foregroundStyle(.secondary)
                if !appState.folderFilingMessage.isEmpty { Text(appState.folderFilingMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Notes") {
                Toggle("Summarize with Apple Intelligence", isOn: $appState.summaryUsesAppleIntelligence)
                Picker("Default format", selection: $appState.summaryTemplate) {
                    ForEach(SummaryTemplate.allCases, id: \.self) { template in Text(template.title).tag(template) }
                }
                .disabled(!appState.summaryUsesAppleIntelligence)
                Text(appState.summaryUsesAppleIntelligence
                     ? FoundationModelsProvider.availability().message
                     : "Notes use excerpts from the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(appState.speechModelStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(appState.isPreparingRecording ? "Checking…" : "Check Recording Setup") {
                        Task { _ = await appState.prepareRecording() }
                    }.disabled(!appState.canStartRecording)
                    Button(appState.isSettingUpSpeechModels ? "Installing…" : "Install Speaker Models") {
                        Task { await appState.setupSpeechModels() }
                    }.disabled(appState.isSettingUpSpeechModels)
                    if appState.isSettingUpSpeechModels { ProgressView().controlSize(.small) }
                }
                if appState.statusMessage.hasPrefix("Recording setup:") || appState.statusMessage == "Ready to record on this device." {
                    Text(appState.statusMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                DisclosureGroup("Fine-tune speaker detection") {
                    LabeledContent("Pause threshold") {
                        Slider(value: $appState.diarizationConfig.pauseThreshold, in: 0.5...3.5, step: 0.1)
                            .frame(maxWidth: 180)
                        Text(String(format: "%.1f s", appState.diarizationConfig.pauseThreshold))
                            .monospacedDigit().frame(width: 46)
                    }
                    LabeledContent("Sensitivity") {
                        Slider(value: $appState.diarizationConfig.aggressiveness, in: 0...1, step: 0.05)
                            .frame(maxWidth: 230)
                    }
                }
            } header: { Text("Speech & speakers") } footer: {
                Text("Transcription runs on this device. Speaker models are installed only when you choose Install.")
            }
        }.formStyle(.grouped)
            .contentMargins(.vertical, 8, for: .scrollContent)
    }

    private var calendar: some View {
        Form {
            Section {
                LabeledContent("Apple Calendar") {
                    connectionStatus(appState.calendarConnected && appState.calendarSource == .apple)
                    Button(appState.calendarConnected && appState.calendarSource == .apple ? "Refresh" : "Connect…") {
                        Task { await appState.connectCalendar() }
                    }
                }
                Text("Use the accounts already added to Apple Calendar.").font(.caption).foregroundStyle(.secondary)
                if appState.calendarSource == .apple && appState.calendarMessage != "Connect accounts configured in Apple Calendar, including Google accounts." {
                    Text(appState.calendarMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    connectionStatus(appState.googleConnected && appState.calendarSource == .google)
                    if appState.googleConnecting { ProgressView().controlSize(.small) }
                    if appState.googleConnected {
                        Button("Disconnect") { Task { await appState.disconnectGoogleCalendar() } }
                    } else {
                        Button(appState.googleConnecting ? "Connecting…" : "Connect…") {
                            Task { await appState.connectGoogleCalendar() }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Google Calendar")
                        Text("Beta").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.25), in: Capsule())
                    }
                }.disabled(appState.googleConnecting)
                if !appState.googleConnected {
                    Text("Google is still reviewing Minutes, so sign-in shows a warning first. Apple Calendar works without it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if appState.googleMessage != "Connect Google directly, or use accounts in Apple Calendar." {
                    Text(appState.googleMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if appState.googleRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating meeting events…").font(.callout).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                GoogleCalendarPicker(appState: appState)
                if appState.googleConnected {
                    Button("Refresh Calendar") { Task { await appState.resumeGoogleCalendar() } }
                        .disabled(appState.googleConnecting || appState.googleRefreshing)
                }
                #if DEBUG
                DisclosureGroup("Advanced") {
                    TextField("Mac client ID", text: $appState.googleDesktopClientID)
                    TextField("iOS client ID", text: $appState.googleIOSClientID)
                    Text("Public OAuth client IDs are required for direct sign-in. Credentials stay in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
            Section("Meeting Reminders") {
                LabeledContent("Notifications") {
                    Text(appState.calendarNotificationsEnabled ? "Enabled" : "Off").foregroundStyle(.secondary)
                    Button("Enable…") { Task { await appState.enableCalendarNotifications() } }
                        .disabled(appState.calendarNotificationsEnabled)
                }
            }
        }.formStyle(.grouped)
            .contentMargins(.vertical, 8, for: .scrollContent)
    }

    private var connections: some View {
        Form {
            LibrarySyncSettings(appState: appState)
            ParachuteVaultSettings(appState: appState)
            if !appState.prismOutbox.isEmpty {
                Section("Earlier Prism deliveries") { deliveries }
            }
            Section("Markdown") {
                Text("Save Markdown… opens the system file picker so you choose the name and location every time.").font(.callout).foregroundStyle(.secondary)
                LabeledContent("CLI default folder") {
                    Text(appState.markdownDirectory.isEmpty ? "Not selected" : URL(fileURLWithPath: appState.markdownDirectory).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(appState.markdownDirectory)
                    Button("Choose…") { choosingMarkdownFolder = true }
                }
                if let folderError { Label(folderError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Advanced") {
                    TextField("Folder path", text: $appState.markdownDirectory)
                    TextField("Legacy CLI endpoint", text: $appState.parachuteHost)
                    Text("Legacy export requires the separate Parachute CLI on Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
            .contentMargins(.vertical, 8, for: .scrollContent)
    }

    private var deliveries: some View {
        DisclosureGroup("Deliveries (\(appState.prismOutbox.count))") {
            ForEach(appState.prismOutbox) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.store.getMeeting(id: item.meetingId)?.title ?? "Meeting")
                        Text(item.status.rawValue.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                        if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if item.status != .synced && item.status != .revoked {
                        Button("Cancel") { Task { await appState.cancelPrismDelivery(id: item.id) } }
                            .disabled(appState.prismBusy)
                    }
                }
            }
            Button("Retry Pending Deliveries") { Task { await appState.syncPrismOutbox() } }
                .disabled(appState.prismBusy)
        }
    }

    private var privacy: some View {
        Form {
            Section("Permissions") {
                permissionRow("Microphone", status: permissions.micStatus) {
                    Task { _ = await permissions.requestMicrophoneAccess() }
                }
                #if os(macOS)
                permissionRow("Call audio", status: permissions.systemAudioStatus) {
                    Task { _ = await permissions.requestSystemAudioAccess() }
                }
                #endif
                permissionRow("Apple Calendar", status: permissions.calendarStatus) {
                    Task { await appState.connectCalendar(); permissions.checkAllPermissions() }
                }
                HStack {
                    Button("Check Again") { permissions.checkAllPermissions() }
                    #if os(macOS)
                    Button("System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { openURL(url) }
                    }
                    #endif
                }
            }
            Section("Your Data") {
                Label("Remembered voices never leave this device.", systemImage: "internaldrive")
                Label("Recordings stay here unless you turn on Include recordings in Sync.", systemImage: "waveform")
                Label("Exports include notes and transcripts, never voice profiles.", systemImage: "doc.text")
                Text("Manage and delete remembered voices in People. Recording begins when you choose Record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .contentMargins(.vertical, 8, for: .scrollContent)
    }

    private func connectionStatus(_ connected: Bool) -> some View {
        Label(connected ? "Connected" : "Not connected", systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func permissionRow(_ title: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            Label(status == .granted ? "Allowed" : status.rawValue, systemImage: status == .granted ? "checkmark.circle" : "circle.dashed")
                .font(.callout).foregroundStyle(.secondary)
            if status != .granted {
                Button(status == .denied ? "Review…" : "Allow…") {
                    #if os(macOS)
                    if status == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { openURL(url) }
                    else { action() }
                    #else
                    action()
                    #endif
                }
                    .disabled(status == .restricted || status == .unavailable)
            }
        }
    }
}
#endif
