#if canImport(SwiftUI)
import Foundation
import Combine
import EventKit
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesCalendar
import MinutesSummarize
import MinutesExport
import MinutesUI

public enum NavigationSection: String, CaseIterable, Identifiable {
    case meetings = "Meetings"
    case calendar = "Calendar"
    case liveIngestion = "Record & Import"
    case voiceprintHub = "People & Voices"
    case onboarding = "Permissions & Privacy"
    case settings = "Settings"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .meetings: return "folder.fill"
        case .calendar: return "calendar"
        case .liveIngestion: return "waveform.circle.fill"
        case .voiceprintHub: return "brain.head.profile"
        case .onboarding: return "lock.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    #if os(macOS)
    lazy var captionPanel = CaptionPanelController()
    #endif
    @Published public var selectedSection: NavigationSection = .meetings
    @Published public var meetings: [Meeting] = []
    @Published public var selectedMeetingId: String? = nil
    
    // Meeting detail state
    @Published public var currentMeeting: Meeting? = nil
    @Published public var currentClusters: [SpeakerCluster] = []
    @Published public var currentUtterances: [Utterance] = []
    @Published public var currentAttendees: [Person] = []
    @Published public var currentSummary: MeetingSummary? = nil
    @Published public var currentBookmarks: [Bookmark] = []
    @Published public var voiceprints: [Voiceprint] = []
    
    // Recording & Ingestion State
    public enum CaptureMode: String, CaseIterable, Identifiable {
        case microphone = "Microphone", systemAudio = "Mac audio only", systemAndMicrophone = "Mac call audio + microphone"
        public var includesMicrophone: Bool { self != .systemAudio }
        public var id: String { rawValue }
    }
    @Published public var captureMode: CaptureMode = .microphone
    @Published public var isStartingRecording = false
    @Published public var isFinalizingRecording = false
    @Published public var captureSourceDirectory: URL?
    private var recordingUsesSystem = false
    #if os(macOS)
    private var systemRecorder: any SystemAudioRecording = SystemAudioCaptureService()
    #endif
    @Published public var isRecording: Bool = false
    @Published public var recordingDuration: Double = 0.0
    public let recordingMeter = RecordingMeterModel()
    public var recordingLevel: Float { recordingMeter.level ?? 0 }
    @Published public var isProcessing: Bool = false
    @Published public var statusMessage: String = "Ready"
    
    @Published public var isSettingUpSpeechModels = false
    @Published public var speechModelStatus = "Check local model availability before recording."

    @Published public var isSummarizing = false
    @Published public var summaryUsesAppleIntelligence = false { didSet { preferences.set(summaryUsesAppleIntelligence, forKey: "summaryUsesAppleIntelligence") } }
    @Published public var summaryTemplate: SummaryTemplate = .general { didSet { preferences.set(summaryTemplate.rawValue, forKey: "summaryTemplate") } }
    // Settings
    @Published public var parachuteHost: String = "http://localhost:1940"
    @Published public var googleDesktopClientID = "" { didSet { preferences.set(googleDesktopClientID, forKey: "googleDesktopClientID") } }
    @Published public var googleIOSClientID = "" { didSet { preferences.set(googleIOSClientID, forKey: "googleIOSClientID") } }
    @Published public var googleCalendarIDs = "primary" { didSet { preferences.set(googleCalendarIDs, forKey: "googleCalendarIDs") } }
    @Published public var googleMessage = "Connect Google directly, or use accounts in Apple Calendar."
    @Published public var googleConnecting = false
    @Published public private(set) var googleRefreshing = false
    @Published public var googleConnected = false
    private var googleConnection: GoogleCalendarConnection?
    private var googleRefreshTask: Task<Void, Never>?
    private var googleAuthorizationTask: Task<Void, any Error>?
    private var googleOperation = 0
    private var googleRestoreAttempted = false
    private var appleCalendarRestoreAttempted = false
    private var calendarGeneration = 0
    public enum CalendarSource: String, CaseIterable, Identifiable { case apple = "Apple Calendar", google = "Google Calendar"; public var id: String { rawValue } }
    @Published public var calendarSource: CalendarSource = .apple
    @Published public var prismOrigin = "https://minutes.omniharmonic.com" {
        didSet {
            preferences.set(prismOrigin, forKey: "prismOrigin")
            if oldValue != prismOrigin { prismOperation += 1; prismAuthorizationTask?.cancel(); prismAuthorizationPending = false; prismBusy = false; prismConnection = nil; prismVerified = false; prismVaults = []; prismOutbox = []; prismMessage = "Server changed. Verify this connection before sending meetings." }
        }
    }
    @Published public var prismVaultID = "" { didSet { preferences.set(prismVaultID, forKey: "prismVaultID") } }
    @Published public var prismVerified = false
    @Published public var prismBusy = false
    @Published public var prismMessage = "Prism server setup is pending. Local meetings remain available."
    @Published public var prismVaults: [PrismMinutesVault] = []
    @Published public var prismOutbox: [OutboxItem] = []
    private var prismConnection: PrismConnection?
    private var prismAuthorizationTask: Task<Void, any Error>?
    private var prismOperation = 0
    private var restoringPrism = false
    private var prismAuthorizationPending = false
    public var canCancelPrismAuthorization: Bool { prismAuthorizationPending }
    private let preferences: UserDefaults
    @Published public var markdownDirectory: String = "" { didSet { preferences.set(markdownDirectory, forKey: "markdownDirectory") } }
    @Published public var diarizationConfig: DiarizationConfig = DiarizationConfig()
    
    @Published public var folders: [MeetingFolder] = []
    @Published public var libraryScope: MeetingLibraryScope = .all
    @Published var folderAssignments: [String: MeetingFolderMembership] = [:]
    @Published public var isOrganizingFolders = false
    @Published public var folderFilingMessage = ""
    @Published public var autoFileMeetingsEnabled = true {
        didSet { preferences.set(autoFileMeetingsEnabled, forKey: "autoFileMeetingsEnabled") }
    }
    var folderLibraryRevision = 0
    var folderFilingInFlight: Set<String> = []

    @Published public var upcomingEvents: [CalendarMeetingEvent] = []
    @Published public var calendarMessage = "Connect accounts configured in Apple Calendar, including Google accounts."
    @Published public var calendarConnected = false
    @Published public var calendarPrompt: CalendarMeetingEvent?
    @Published public var calendarNotificationsEnabled = false
    private let calendarProvider: any CalendarProviding
    private var calendarTimer: AnyCancellable?
    private var calendarRefreshObservers: [AnyCancellable] = []
    private var suppressedCalendarPrompts: Set<String> = []
    private var dismissedCalendarEvents: Set<String> = []
    private var scheduledCalendarNotifications: Set<String> = []

    public let store: MinutesStore
    public let permissionManager = PermissionManager.shared
    private var recordingTimer: AnyCancellable?
    private var activeRecordingURL: URL?
    private var recordingPlaceholderTitle: String?
    private var recordingMeetingId: String? { didSet { objectWillChange.send() } }
    
    private let recordingModelReadiness: @Sendable () -> (ready: Bool, reason: String)
    private let recordingEnvironmentPreflight: (@Sendable () async throws -> Void)?
    private let audioDirectory: URL?
    private let captureStart: (URL) throws -> Void
    private let captureStop: () throws -> URL?
    private let captureMetrics: () -> (duration: Double, level: Float, error: String?)
    private let captureNotice: () -> String?
    private var lastCaptureNotice: String?
    public var recordingRouteNotice: String? { lastCaptureNotice }
    let classifyMeetingFolder: @Sendable (FolderClassificationInput, [FolderClassificationCandidate]) async -> FolderClassificationResult
    private let summarizeMeeting: @Sendable (Meeting, [Utterance], [Person], SummaryTemplate, Bool) async throws -> MeetingSummary
    private let processAudio: @Sendable (String, URL, DiarizationConfig) async throws -> PipelineResult

    public init(
        store: MinutesStore? = nil,
        databasePath: String? = nil,
        calendarProvider: (any CalendarProviding)? = nil,
        audioDirectory: URL? = nil,
        preferences: UserDefaults = .standard,
        prismConnection: PrismConnection? = nil,
        recordingModelReadiness: @escaping @Sendable () -> (ready: Bool, reason: String) = { ModelManager.shared.diarizationReadiness() },
        recordingEnvironmentPreflight: (@Sendable () async throws -> Void)? = nil,
        captureStart: @escaping (URL) throws -> Void = { try AudioCaptureService.shared.startRecording(to: $0) },
        captureStop: @escaping () throws -> URL? = { try AudioCaptureService.shared.stopRecording() },
        captureMetrics: @escaping () -> (duration: Double, level: Float, error: String?) = {
            (AudioCaptureService.shared.recordedDuration, AudioCaptureService.shared.currentLevel, AudioCaptureService.shared.captureError)
        },
        captureNotice: @escaping () -> String? = { AudioCaptureService.shared.captureNotice },
        processAudio: @escaping @Sendable (String, URL, DiarizationConfig) async throws -> PipelineResult = {
            try await PipelineOrchestrator().process(meetingId: $0, audioURL: $1, config: $2)
        },
        classifyMeetingFolder: @escaping @Sendable (FolderClassificationInput, [FolderClassificationCandidate]) async -> FolderClassificationResult = {
            await FolderClassifier().classify(input: $0, candidates: $1)
        },
        summarizeMeeting: @escaping @Sendable (Meeting, [Utterance], [Person], SummaryTemplate, Bool) async throws -> MeetingSummary = { meeting, utterances, attendees, template, apple in
            let provider: (any LLMProvider)? = apple ? FoundationModelsProvider() : nil
            return try await Summarizer(provider: provider).summarize(meeting: meeting, utterances: utterances, attendees: attendees, template: template)
        }
    ) throws {
        self.recordingModelReadiness = recordingModelReadiness
        self.recordingEnvironmentPreflight = recordingEnvironmentPreflight
        self.preferences = preferences
        self._autoFileMeetingsEnabled = Published(initialValue: preferences.object(forKey: "autoFileMeetingsEnabled") as? Bool ?? true)
        self.calendarProvider = calendarProvider ?? EventKitCalendarProvider()
        self.audioDirectory = audioDirectory
        self.captureStart = captureStart
        self.captureStop = captureStop
        self.captureMetrics = captureMetrics
        self.captureNotice = captureNotice
        self.processAudio = processAudio
        self.classifyMeetingFolder = classifyMeetingFolder
        self.summarizeMeeting = summarizeMeeting
        let home = NSHomeDirectory()
        let dbPath = (home as NSString).appendingPathComponent("Library/Application Support/Minutes/minutes.db")
        let mdDir = (home as NSString).appendingPathComponent("Documents/Minutes")
        self.markdownDirectory = preferences.string(forKey: "markdownDirectory") ?? mdDir
        
        self.store = try store ?? MinutesStore(dbPath: databasePath ?? dbPath)
        self._summaryUsesAppleIntelligence = Published(initialValue: FoundationModelsProvider.initialPreference(
            savedChoice: preferences.object(forKey: "summaryUsesAppleIntelligence") as? Bool,
            availability: FoundationModelsProvider.availability()))
        self.summaryTemplate = SummaryTemplate(rawValue: preferences.string(forKey: "summaryTemplate") ?? "") ?? .general
        self.googleDesktopClientID = preferences.string(forKey: "googleDesktopClientID").flatMap { $0.isEmpty ? nil : $0 } ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleDesktopClientID") as? String) ?? ""
        self.googleIOSClientID = preferences.string(forKey: "googleIOSClientID").flatMap { $0.isEmpty ? nil : $0 } ?? (Bundle.main.object(forInfoDictionaryKey: "GoogleIOSClientID") as? String) ?? ""
        self.googleCalendarIDs = preferences.string(forKey: "googleCalendarIDs") ?? "primary"
        self.prismOrigin = preferences.string(forKey: "prismOrigin") ?? "https://minutes.omniharmonic.com"
        self.prismVaultID = preferences.string(forKey: "prismVaultID") ?? ""
        self.prismConnection = prismConnection
        let interruptedCount = try self.store.markAbandonedRecordingsInterrupted()
        try self.store.seedStarterFoldersIfNeeded()
        loadInitialData()
        refreshSpeechReadiness()
        if interruptedCount > 0 {
            statusMessage = "An earlier recording was interrupted. Saved audio may be incomplete. Select the meeting to review or process a recovery copy."
        }
    }

    #if os(macOS)
    public convenience init(store: MinutesStore, audioDirectory: URL, systemRecorder: any SystemAudioRecording,
        recordingModelReadiness: @escaping @Sendable () -> (ready: Bool, reason: String) = { ModelManager.shared.diarizationReadiness() },
        processAudio: @escaping @Sendable (String, URL, DiarizationConfig) async throws -> PipelineResult = { try await PipelineOrchestrator().process(meetingId: $0, audioURL: $1, config: $2) }) throws {
        try self.init(store: store, audioDirectory: audioDirectory, recordingModelReadiness: recordingModelReadiness, processAudio: processAudio)
        self.systemRecorder = systemRecorder
    }

    public func startSystemMeeting(event: CalendarMeetingEvent? = nil, includeMicrophone: Bool = true) async {
        guard requireRecordingModels() else { return }
        guard !isRecording, !isProcessing, !isStartingRecording, !isFinalizingRecording else { return }
        lastCaptureNotice = nil
        AudioPlaybackService.shared.stop()
        isStartingRecording = true
        defer { isStartingRecording = false }
        let id = UUID().uuidString.lowercased()
        let base = audioDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Minutes/Audio", isDirectory: true)
        let directory = base.appendingPathComponent(id, isDirectory: true)
        var meeting = Meeting(id: id, title: event?.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))", status: "starting", audioPath: nil)
        meeting.platform = "system_audio"
        do {
            try store.saveMeeting(meeting)
            try fileNewMeetingInSelectedFolder(id: meeting.id)
            if let event { meeting = try CalendarMeetingBinder.bind(meetingId: id, event: event, store: store) }
            try await systemRecorder.startRecording(to: directory, includeMicrophone: includeMicrophone)
            meeting.status = "recording"
            try store.saveMeeting(meeting)
        } catch {
            if systemRecorder.capturing { _ = try? await systemRecorder.stopRecording() }
            meeting.status = "failed"
            do { try store.saveMeeting(meeting) } catch { statusMessage = "Recording failed; could not save failure: \(error.localizedDescription)"; return }
            statusMessage = "System recording failed: \(error.localizedDescription)"
            captureSourceDirectory = FileManager.default.fileExists(atPath: directory.path) ? directory : nil
            loadInitialData(); selectMeeting(id: id)
            return
        }
        recordingUsesSystem = true
        recordingPlaceholderTitle = event == nil ? meeting.title : nil
        recordingMeetingId = id
        captureSourceDirectory = directory
        isRecording = true; recordingDuration = 0; recordingMeter.reset(level: nil)
        captionPanel.begin()
        statusMessage = includeMicrophone
            ? "Recording call audio and microphone as separate local tracks. Use headphones to reduce echo."
            : "Recording Mac audio only. Microphone is off."
        if let event { suppressedCalendarPrompts.insert(event.id); dismissCalendarPrompt(eventID: event.id) }
        let started = Date()
        recordingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let duration = Date().timeIntervalSince(started)
            self.recordingMeter.update(duration: duration, level: nil)
            self.publishRecordingDuration(duration)
            if self.systemRecorder.captureError != nil { Task { await self.stopAndProcessMeeting() } }
        }
        loadInitialData(); selectMeeting(id: id)
    }
    #endif

    @Published public private(set) var recordingModelsReady = false
    @Published public private(set) var isPreparingRecording = false
    public var activeRecordingMeetingID: String? { recordingMeetingId }
    public var canStartRecording: Bool { recordingModelsReady && !isRecording && !isProcessing && !isStartingRecording && !isFinalizingRecording && !isSettingUpSpeechModels && !isPreparingRecording }
    public func prepareRecording() async -> Bool {
        guard !isPreparingRecording, !isRecording, !isProcessing, !isStartingRecording, !isFinalizingRecording else { return false }
        refreshSpeechReadiness()
        guard recordingModelsReady else { statusMessage = speechModelStatus; return false }
        isPreparingRecording = true
        defer { isPreparingRecording = false }
        do {
            if let recordingEnvironmentPreflight { try await recordingEnvironmentPreflight() }
            else {
                try ModelManager.shared.validateDiarizationModels()
                try await ASRService().prepareForRecording()
                if captureMode.includesMicrophone {
                    guard await PermissionManager.shared.requestMicrophoneAccess() else {
                        throw ASRError.audioUnreadable("Allow microphone access in System Settings before recording.")
                    }
                }
            }
            refreshSpeechReadiness()
            guard recordingModelsReady else { statusMessage = speechModelStatus; return false }
            statusMessage = "Ready to record on this device."
            return true
        } catch { statusMessage = "Recording setup: \(error.localizedDescription)"; return false }
    }

    private func requireRecordingModels() -> Bool {
        refreshSpeechReadiness()
        guard recordingModelsReady, !isSettingUpSpeechModels else {
            statusMessage = "Install local speaker models before recording. " + speechModelStatus
            return false
        }
        return true
    }

    public func refreshSpeechReadiness() {
        let readiness = recordingModelReadiness()
        recordingModelsReady = readiness.ready
        speechModelStatus = readiness.reason
    }

    public func setupSpeechModels() async {
        guard !isSettingUpSpeechModels else { return }
        isSettingUpSpeechModels = true
        speechModelStatus = "Downloading and verifying local speaker models..."
        defer { isSettingUpSpeechModels = false }
        do {
            try await ModelManager.shared.setupDiarizationModels()
            refreshSpeechReadiness()
        } catch { speechModelStatus = "Model setup failed: \(error.localizedDescription)" }
    }


    private func googleConfiguration() -> GoogleCalendarConfiguration {
        GoogleCalendarConfiguration(desktopClientID: googleDesktopClientID.isEmpty ? nil : googleDesktopClientID,
            iOSClientID: googleIOSClientID.isEmpty ? nil : googleIOSClientID,
            calendarIDs: googleCalendarIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    public func connectGoogleCalendar(using agent: (any GoogleOAuthUserAgent)? = nil, connection supplied: GoogleCalendarConnection? = nil) async {
        guard !googleConnecting else { return }
        googleOperation += 1; let operation = googleOperation
        googleConnecting = true
        calendarGeneration += 1; googleRefreshTask?.cancel(); googleRefreshTask = nil; googleRefreshing = false; calendarTimer?.cancel()
        upcomingEvents = []; calendarPrompt = nil; calendarConnected = false; googleConnected = false
        defer { if operation == googleOperation { googleConnecting = false; googleAuthorizationTask = nil } }
        do {
            let connection = supplied ?? GoogleCalendarConnection(configuration: googleConfiguration())
            googleConnection = connection // Disconnect can invalidate an authorization while its browser is still open.
            googleMessage = "Waiting for Google authorization in your browser…"
            let browser = agent ?? GoogleSystemBrowserAgent()
            let authorization = Task { try await connection.connect(using: browser) }
            googleAuthorizationTask = authorization
            try await withTaskCancellationHandler { try await authorization.value } onCancel: { authorization.cancel() }
            guard operation == googleOperation, !Task.isCancelled else { return }
            googleConnected = true; calendarConnected = true; calendarSource = .google
            preferences.set("google", forKey: "calendarProvider")
            calendarGeneration += 1
            calendarTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshCalendar() }
            googleConnecting = false
            googleMessage = "Google connected. Refreshing upcoming meetings…"
            let refresh = beginGoogleCalendarRefresh(now: Date())
            await withTaskCancellationHandler { await refresh.value } onCancel: { refresh.cancel() }
        } catch {
            guard operation == googleOperation, !Task.isCancelled else { return }
            googleMessage = "Google connection failed: \(error.localizedDescription)"
        }
    }

    /// Restore the selected calendar without requesting new permission or opening sign-in UI.
    public func restoreCalendarConnections(connection supplied: GoogleCalendarConnection? = nil) async {
        guard preferences.string(forKey: "calendarProvider") == "apple" else {
            await restoreGoogleCalendar(connection: supplied)
            return
        }
        guard !appleCalendarRestoreAttempted, !calendarConnected, !googleConnecting else { return }
        appleCalendarRestoreAttempted = true
        calendarSource = .apple
        guard calendarProvider.hasAccess else {
            calendarMessage = "Apple Calendar access is unavailable. Choose Connect Apple Calendar to grant access."
            return
        }
        activateAppleCalendarConnection()
    }

    /// Resume only saved access; startup never launches a browser or requests Keychain UI.
    public func restoreGoogleCalendar(connection supplied: GoogleCalendarConnection? = nil) async {
        guard !googleRestoreAttempted, !googleConnecting else { return }
        googleRestoreAttempted = true
        let provider = preferences.string(forKey: "calendarProvider")
        guard provider == nil || provider == "google" else { return }
        await resumeGoogleCalendar(connection: supplied, allowInteraction: false)
    }
    public func resumeGoogleCalendar(connection supplied: GoogleCalendarConnection? = nil, allowInteraction: Bool = true) async {
        guard !googleConnecting else { return }
        googleOperation += 1; let operation = googleOperation
        googleConnecting = true
        defer { if operation == googleOperation { googleConnecting = false } }
        let connection = supplied ?? GoogleCalendarConnection(configuration: googleConfiguration(), credentialStore: KeychainOAuthCredentialStore(allowInteraction: allowInteraction))
        do {
            let saved = try await connection.status(allowInteraction: allowInteraction)
            guard operation == googleOperation, !Task.isCancelled else { return }
            guard saved.connected else { googleMessage = "No saved Google connection. Choose Connect Google."; return }
            googleConnection = connection; googleConnected = true; calendarConnected = true; calendarSource = .google
            preferences.set("google", forKey: "calendarProvider")
            calendarGeneration += 1; googleRefreshTask?.cancel(); googleRefreshTask = nil; googleRefreshing = false; calendarTimer?.cancel()
            calendarTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshCalendar() }
            googleConnecting = false
            googleMessage = "Google connected. Refreshing upcoming meetings…"
            let refresh = beginGoogleCalendarRefresh(now: Date())
            await withTaskCancellationHandler { await refresh.value } onCancel: { refresh.cancel() }
        } catch {
            guard operation == googleOperation, !Task.isCancelled else { return }
            googleMessage = "Google connection unavailable: \(error.localizedDescription) Choose Reconnect Saved Account to retry."
        }
    }

    public func disconnectGoogleCalendar() async {
        preferences.set("none", forKey: "calendarProvider")
        googleOperation += 1; let operation = googleOperation
        googleAuthorizationTask?.cancel(); googleAuthorizationTask = nil
        googleConnecting = true
        defer { if operation == googleOperation { googleConnecting = false } }
        calendarGeneration += 1; googleRefreshTask?.cancel(); googleRefreshTask = nil; googleRefreshing = false
        let connection = googleConnection
        googleConnection = nil; googleConnected = false
        if calendarSource == .google || !calendarConnected {
            calendarConnected = false; upcomingEvents = []; calendarPrompt = nil; calendarTimer?.cancel()
            if !scheduledCalendarNotifications.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(scheduledCalendarNotifications))
                scheduledCalendarNotifications = []
            }
        }
        do {
            try await connection?.disconnect()
            guard operation == googleOperation else { return }
            googleMessage = "Google authorization removed from this device."
        } catch {
            guard operation == googleOperation else { return }
            googleMessage = "Disconnected locally. Google revocation was not confirmed: \(error.localizedDescription)"
        }
    }

    private func beginGoogleCalendarRefresh(now: Date) -> Task<Void, Never> {
        let generation = calendarGeneration
        googleRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.calendarGeneration {
                    self.googleRefreshTask = nil
                    self.googleRefreshing = false
                }
            }
            await self.refreshGoogleCalendar(now: now)
        }
        googleRefreshTask = task
        return task
    }

    private func refreshGoogleCalendar(now: Date) async {
        guard let connection = googleConnection, calendarSource == .google else { return }
        let generation = calendarGeneration
        do {
            let events = try await connection.events(in: DateInterval(start: now, duration: 7 * 86400))
            guard generation == calendarGeneration, !Task.isCancelled, calendarSource == .google else { return }
            upcomingEvents = events
            calendarMessage = "\(events.count) upcoming Google meetings. Invitees are not confirmed speakers."
            googleMessage = "Google connected · read-only calendar access"
            if !isRecording && !isProcessing && calendarPrompt == nil {
                let recorded = Set(store.listMeetings().compactMap(\.calendarEventId))
                calendarPrompt = CalendarMeetingEvent.nextPrompt(in: events, now: now, suppressedIDs: suppressedCalendarPrompts.union(recorded))
                if let prompt = calendarPrompt { suppressedCalendarPrompts.insert(prompt.id) }
            }
            if calendarNotificationsEnabled { await scheduleCalendarNotifications(now: now) }
        } catch {
            guard generation == calendarGeneration, !Task.isCancelled else { return }
            calendarMessage = "Google refresh failed: \(error.localizedDescription)"
            googleMessage = calendarMessage; upcomingEvents = []; calendarPrompt = nil
        }
    }

    public func connectCalendar() async {
        preferences.set("apple", forKey: "calendarProvider")
        googleOperation += 1; googleAuthorizationTask?.cancel(); googleAuthorizationTask = nil; googleConnecting = false
        calendarTimer?.cancel()
        calendarGeneration += 1
        googleRefreshTask?.cancel(); googleRefreshTask = nil; googleRefreshing = false
        calendarSource = .apple
        do {
            try await calendarProvider.requestAccess()
            activateAppleCalendarConnection()
        } catch {
            calendarConnected = false
            upcomingEvents = []
            calendarMessage = error.localizedDescription
        }
    }

    private func activateAppleCalendarConnection() {
        calendarTimer?.cancel()
        calendarConnected = true
        refreshCalendar()
        calendarRefreshObservers = [NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCalendar() },
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCalendar() }]
        #if canImport(AppKit)
        calendarRefreshObservers.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCalendar() })
        calendarRefreshObservers.append(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCalendar() })
        #endif
        calendarTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshCalendar() }
    }

    public func refreshCalendar(now: Date = Date()) {
        guard calendarConnected else { return }
        if calendarSource == .google {
            // A slow request owns its lifetime; timer ticks never multiply or cancel it.
            if googleRefreshTask == nil { _ = beginGoogleCalendarRefresh(now: now) }
            return
        }
        do {
            upcomingEvents = try calendarProvider.events(in: DateInterval(start: now, duration: 7 * 86400))
            calendarMessage = "\(upcomingEvents.count) upcoming timed meetings from Apple Calendar accounts. Invitees are not confirmed speakers."
            if !isRecording && !isProcessing && calendarPrompt == nil {
                let recorded = Set(store.listMeetings().compactMap(\.calendarEventId))
                calendarPrompt = CalendarMeetingEvent.nextPrompt(in: upcomingEvents, now: now,
                    suppressedIDs: suppressedCalendarPrompts.union(recorded))
                if let prompt = calendarPrompt { suppressedCalendarPrompts.insert(prompt.id) }
            }
            if calendarNotificationsEnabled { Task { await scheduleCalendarNotifications(now: now) } }
        } catch {
            upcomingEvents = []
            calendarPrompt = nil
            calendarMessage = error.localizedDescription
            if calendarNotificationsEnabled {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(scheduledCalendarNotifications))
                scheduledCalendarNotifications = []
            }
        }
    }

    public func dismissCalendarPrompt(eventID: String) {
        dismissedCalendarEvents.insert(eventID)
        calendarPrompt = nil
        if calendarNotificationsEnabled {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["minutes-calendar-" + eventID])
        }
    }

    public func enableCalendarNotifications() async {
        do {
            calendarNotificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if calendarNotificationsEnabled { await scheduleCalendarNotifications(now: Date()) }
            else { calendarMessage = "Calendar notifications are disabled in system settings. You can still record from the event list." }
        } catch { calendarMessage = error.localizedDescription }
    }

    private func scheduleCalendarNotifications(now: Date) async {
        let center = UNUserNotificationCenter.current()
        let events = upcomingEvents.filter { $0.start > now && !dismissedCalendarEvents.contains($0.id) }.prefix(60)
        let ids = Set(events.map { "minutes-calendar-" + $0.id })
        center.removePendingNotificationRequests(withIdentifiers: Array(scheduledCalendarNotifications.subtracting(ids)))
        let existingIDs = scheduledCalendarNotifications
        scheduledCalendarNotifications = ids
        for event in events where !existingIDs.contains("minutes-calendar-" + event.id) {
            let content = UNMutableNotificationContent()
            content.title = "Meeting starting: " + event.title
            content.body = "Open Minutes to review invitees and start recording."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, event.start.timeIntervalSince(now) - 120), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: "minutes-calendar-" + event.id, content: content, trigger: trigger)) }
            catch { calendarMessage = "Could not schedule meeting notification: \(error.localizedDescription)" }
        }
    }

    public func loadInitialData() {
        self.meetings = store.listMeetings()
        self.voiceprints = store.listVoiceprints()
        reloadFolderLibrary()
        if let first = meetings.first {
            selectMeeting(id: first.id)
        }
    }
    
    public func selectMeeting(id: String?) {
        guard let id = id else { return }
        self.selectedMeetingId = id
        self.currentMeeting = store.getMeeting(id: id)
        self.currentClusters = store.listSpeakerClusters(meetingId: id)
        self.currentUtterances = TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: id), clusters: currentClusters)
        self.currentSummary = store.getSummary(meetingId: id)
        self.currentBookmarks = store.listBookmarks(meetingId: id)
        self.currentAttendees = store.listPeopleForMeeting(meetingId: id)
        self.voiceprints = store.listVoiceprints()
    }
    
    public func startQuickMeeting(event: CalendarMeetingEvent? = nil) {
        guard requireRecordingModels() else { return }
        #if os(macOS)
        if captureMode != .microphone {
            let includeMicrophone = captureMode.includesMicrophone
            Task { await startSystemMeeting(event: event, includeMicrophone: includeMicrophone) }
            return
        }
        #endif
        guard !isStartingRecording, !isFinalizingRecording else { return }
        recordingUsesSystem = false
        captureSourceDirectory = nil
        guard !isRecording, !isProcessing, !isFinalizingRecording, !isStartingRecording else { return }
        lastCaptureNotice = nil
        AudioPlaybackService.shared.stop()
        let mId = UUID().uuidString.lowercased()
        let audioDir = audioDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Minutes/audio", isDirectory: true)
        let targetAudioURL = audioDir.appendingPathComponent("meeting_\(mId).wav")
        let meetingTitle = "Meeting (\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)))"
        var meeting = Meeting(id: mId, title: meetingTitle, status: "starting", audioPath: targetAudioURL.path)
        do {
            try store.saveMeeting(meeting)
            try fileNewMeetingInSelectedFolder(id: meeting.id)
            if let event {
                meeting = try CalendarMeetingBinder.bind(meetingId: mId, event: event, store: store)
                suppressedCalendarPrompts.insert(event.id)
                dismissCalendarPrompt(eventID: event.id)
            }
            try captureStart(targetAudioURL)
            meeting.status = "recording"
            try store.saveMeeting(meeting)
        } catch {
            // Stop any partially started engine if capture or the final save failed.
            _ = try? captureStop()
            meeting.status = "failed"
            do { try store.saveMeeting(meeting) }
            catch { statusMessage = "Recording failed; could not save failure: \(error.localizedDescription)"; return }
            statusMessage = "Recording failed: \(error.localizedDescription)"
            loadInitialData()
            return
        }
        self.activeRecordingURL = targetAudioURL
        self.recordingMeetingId = mId
        recordingPlaceholderTitle = event == nil ? meeting.title : nil
        isRecording = true
        #if os(macOS)
        captionPanel.begin()
        #endif
        recordingDuration = 0.0
        recordingMeter.reset()
        loadInitialData()
        selectMeeting(id: mId)
        statusMessage = "Recording microphone audio on this device."

        recordingTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateMicrophoneCaptureMetrics() }
    }

    func updateMicrophoneCaptureMetrics() {
        guard isRecording, !recordingUsesSystem else { return }
        let metrics = captureMetrics()
        recordingMeter.update(duration: metrics.duration, level: metrics.level)
        publishRecordingDuration(recordingMeter.duration)
        if let notice = captureNotice(), notice != lastCaptureNotice {
            lastCaptureNotice = notice
            statusMessage = notice
        }
        if metrics.error != nil { Task { await self.stopAndProcessMeeting() } }
    }

    private func publishRecordingDuration(_ duration: Double) {
        // High-frequency samples stay in recordingMeter. Publish app-wide only
        // once at the first real frame, then on whole-second display boundaries.
        if (recordingDuration == 0 && duration > 0) || floor(duration) != floor(recordingDuration) {
            recordingDuration = duration
        }
    }

    public func stopAndProcessMeeting() async {
        guard isRecording, !isFinalizingRecording, let mId = recordingMeetingId else { return }
        isFinalizingRecording = true
        defer { isFinalizingRecording = false }
        isRecording = false
        #if os(macOS)
        captionPanel.finish()
        #endif
        recordingMeter.finish()
        if recordingDuration != recordingMeter.duration { recordingDuration = recordingMeter.duration }
        recordingTimer?.cancel()
        let placeholderTitle = recordingPlaceholderTitle
        let routeNotice = lastCaptureNotice ?? captureNotice()
        defer { if let routeNotice { statusMessage += " " + routeNotice } }
        defer { activeRecordingURL = nil; recordingMeetingId = nil; recordingUsesSystem = false; recordingPlaceholderTitle = nil }
        let audioURL: URL
        do {
            #if os(macOS)
            if recordingUsesSystem {
                let result = try await systemRecorder.stopRecording()
                captureSourceDirectory = result.directory
                guard let mixed = result.processingURL else { throw CaptureFinalizationError(result: result) }
                audioURL = mixed
            } else {
                guard let recordedURL = try captureStop() else { throw ASRError.audioUnreadable("Recorder did not return a finalized audio file") }
                audioURL = recordedURL
            }
            #else
            guard let recordedURL = try captureStop() else { throw ASRError.audioUnreadable("Recorder did not return a finalized audio file") }
            audioURL = recordedURL
            #endif
            // A header-only or corrupt file cannot be reported as a successful recording.
            let decoded = try AudioDecoder.decode(fileURL: audioURL, targetSampleRate: 16000)
            guard !decoded.samples.isEmpty else { throw ASRError.audioUnreadable("Recording contains no audio frames") }
            // The finalized file is authoritative; the last live poll can trail
            // Stop by one timer interval (and system capture uses a wall clock).
            recordingMeter.finish(duration: decoded.duration)
            if recordingDuration != decoded.duration { recordingDuration = decoded.duration }
        } catch {
            if var meeting = store.getMeeting(id: mId) {
                meeting.status = "failed"
                do { try store.saveMeeting(meeting) }
                catch { statusMessage = "Recording failed; could not save failure: \(error.localizedDescription)"; return }
            }
            if let failure = error as? CaptureFinalizationError { captureSourceDirectory = failure.result.directory }
            statusMessage = "Recording failed: \(error.localizedDescription)" + (captureSourceDirectory.map { " Source audio is preserved in \($0.path)." } ?? "")
            loadInitialData()
            selectMeeting(id: mId)
            return
        }

        isProcessing = true
        isFinalizingRecording = false
        defer { isProcessing = false }
        statusMessage = "Processing recorded speech on device..."
        
        do { _ = try persistProcessingState(meetingId: mId, status: "processing", audioURL: audioURL, endedAt: Date()) }
        catch {
            statusMessage = "Audio preserved, but could not save processing state: \(error.localizedDescription)"
            return
        }
        if FileManager.default.fileExists(atPath: audioURL.path) {
            do {
                let result = try await processAudio(mId, audioURL, diarizationConfig)
                _ = try persistProcessingState(meetingId: mId, status: "needs_review", result: result)
                await completeRecordedMeeting(meetingID: mId, placeholderTitle: placeholderTitle)
                await automaticallyFileMeeting(id: mId)
            } catch {
                statusMessage = "Audio preserved; processing failed: \(error.localizedDescription)"
                do { _ = try persistProcessingState(meetingId: mId, status: "recorded") }
                catch { statusMessage += "; could not save failure state: \(error.localizedDescription)" }
            }
        } else {
            statusMessage = "Recording file disappeared before processing."
            do { _ = try persistProcessingState(meetingId: mId, status: "failed") }
            catch { statusMessage += " Could not save failure state: \(error.localizedDescription)" }
        }

        let selection = selectedMeetingId
        loadInitialData()
        selectMeeting(id: selection.flatMap { store.getMeeting(id: $0) != nil ? $0 : nil } ?? mId)
    }

    /// Complete the captured meeting, independent of whichever meeting is open now.
    private func completeRecordedMeeting(meetingID: String, placeholderTitle: String?) async {
        let utterances = store.listUtterances(meetingId: meetingID)
        guard utterances.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            statusMessage = "No speech was detected. Audio is saved locally; no notes were created."
            return
        }
        do {
            if let placeholderTitle, let title = MeetingTitleGenerator.suggest(from: utterances) {
                try store.withImmediateTransaction {
                    guard var latest = store.getMeeting(id: meetingID) else { return }
                    if latest.title == placeholderTitle {
                        latest.title = title
                        try store.saveMeeting(latest)
                    }
                }
            }
            guard let meeting = store.getMeeting(id: meetingID) else {
                statusMessage = "The meeting was removed. Saved audio was preserved."
                return
            }
            // Automatic completion never replaces notes the user already created.
            let baseline = try summarySnapshot(store.getSummary(meetingId: meetingID))
            guard baseline == nil else {
                statusMessage = "Recording processed. Your existing summary is preserved."
                return
            }
            let attendees = store.listPeopleForMeeting(meetingId: meetingID)
            let template = summaryTemplate
            let apple = summaryUsesAppleIntelligence
            isSummarizing = true
            defer { isSummarizing = false }
            statusMessage = apple ? "Preparing notes with Apple's on-device model…" : "Preparing notes from the transcript…"
            let generated: MeetingSummary
            var fallbackReason: String?
            do {
                generated = try await summarizeMeeting(meeting, utterances, attendees, template, apple)
            } catch {
                // Summarization failure must not turn a valid recording into a failed one.
                fallbackReason = error.localizedDescription
                generated = try await Summarizer().summarize(meeting: meeting, utterances: utterances,
                                                            attendees: attendees, template: template)
            }
            var saved = false
            try store.withImmediateTransaction {
                guard let latest = store.getMeeting(id: meetingID),
                      latest.title == meeting.title, latest.userNotes == meeting.userNotes,
                      try summarySnapshot(store.getSummary(meetingId: meetingID)) == baseline else { return }
                try store.saveSummary(generated)
                saved = true
            }
            if saved {
                if currentMeeting?.id == meetingID { currentSummary = generated }
                if let fallbackReason {
                    statusMessage = "Recording saved. Automatic summary failed: \(fallbackReason) Transcript highlights are saved; no AI summary was generated."
                } else if Summarizer.hasOnlyIntroductions(utterances: utterances, userNotes: meeting.userNotes) {
                    statusMessage = generated.overview
                } else {
                    statusMessage = apple
                        ? "Recording and on-device AI draft saved. Review speakers and notes before sharing."
                        : "Recording and transcript highlights saved. Enable Apple Intelligence summaries for an AI draft."
                }
            } else {
                statusMessage = "Recording processed. Changes made while preparing notes were preserved."
            }
        } catch {
            statusMessage = "Recording and transcript saved; automatic notes could not be saved: \(error.localizedDescription)"
        }
    }
    
    @discardableResult
    public func importMedia(from source: URL, title: String? = nil, isTranscript: Bool = false) async throws -> Meeting {
        guard !isRecording && !isProcessing && !isFinalizingRecording && !isStartingRecording else {
            throw ASRError.transcriptionFailed("Finish the active recording or processing job before importing")
        }
        isProcessing = true
        defer { isProcessing = false }
        let directory = audioDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes/audio", isDirectory: true)
        let importer = AudioImportService(store: store, audioDirectory: directory)
        var meeting = try isTranscript ? importer.importTranscript(from: source, title: title) : importer.importAudio(from: source, title: title)
        try fileNewMeetingInSelectedFolder(id: meeting.id)
        statusMessage = isTranscript ? "Transcript imported without verified timestamps or speakers." : "Audio saved locally; processing on device..."
        loadInitialData()
        selectMeeting(id: meeting.id)
        if !isTranscript, let path = meeting.audioPath {
            do {
                let result = try await processAudio(meeting.id, URL(fileURLWithPath: path), diarizationConfig)
                meeting = try persistProcessingState(meetingId: meeting.id, status: "needs_review", result: result)
                await completeRecordedMeeting(meetingID: meeting.id, placeholderTitle: nil)
            } catch {
                statusMessage = "Audio saved locally; processing pending: \(error.localizedDescription)"
                do { meeting = try persistProcessingState(meetingId: meeting.id, status: "recorded") }
                catch { statusMessage += "; could not save processing state: \(error.localizedDescription)" }
            }
        }
        loadInitialData()
        selectMeeting(id: meeting.id)
        selectedSection = .meetings
        await automaticallyFileMeeting(id: meeting.id)
        return meeting
    }

    public func processCurrentMeeting() async {
        guard !isRecording && !isProcessing && !isFinalizingRecording && !isStartingRecording else { return }
        guard let meeting = currentMeeting, let path = meeting.audioPath else {
            statusMessage = "Select a saved audio recording to process. Untimed transcript imports have no audio."
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        var recoveredCopy: URL?
        var recoveredPathSaved = false
        do {
            if meeting.status == "interrupted" {
                let directory = audioDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Minutes/audio", isDirectory: true)
                recoveredCopy = try InterruptedWAVRecovery.makeCopy(original: URL(fileURLWithPath: path), meetingID: meeting.id, managedAudioDirectory: directory)
            }
            _ = try persistProcessingState(meetingId: meeting.id, status: "processing", audioURL: recoveredCopy)
            recoveredPathSaved = recoveredCopy != nil
            statusMessage = "Processing saved audio on device..."
            let result = try await processAudio(meeting.id, recoveredCopy ?? URL(fileURLWithPath: path), diarizationConfig)
            _ = try persistProcessingState(meetingId: meeting.id, status: "needs_review", result: result)
            await completeRecordedMeeting(meetingID: meeting.id, placeholderTitle: nil)
            await automaticallyFileMeeting(id: meeting.id)
        } catch {
            statusMessage = "Audio preserved; processing pending: \(error.localizedDescription)"
            do { _ = try persistProcessingState(meetingId: meeting.id, status: meeting.status == "interrupted" && !recoveredPathSaved ? "interrupted" : "recorded") }
            catch { statusMessage += "; could not save processing state: \(error.localizedDescription)" }
        }
        loadInitialData()
        selectMeeting(id: meeting.id)
    }

    /// Merge only pipeline-owned fields into the latest row after async processing.
    @discardableResult
    private func persistProcessingState(meetingId: String, status: String, audioURL: URL? = nil, endedAt: Date? = nil, result: PipelineResult? = nil) throws -> Meeting {
        var updated: Meeting?
        try store.withImmediateTransaction {
            guard var latest = store.getMeeting(id: meetingId) else {
                throw NSError(domain: "MinutesApp", code: 404, userInfo: [NSLocalizedDescriptionKey: "The meeting was removed while processing; saved audio was preserved."])
            }
            latest.status = status
            if let audioURL { latest.audioPath = audioURL.path }
            if let endedAt { latest.endedAt = endedAt }
            if let result {
                let identified = RememberedSpeakerIdentification.apply(
                    clusters: result.clusters, utterances: result.utterances,
                    people: store.listPeople(), voiceprints: store.listVoiceprints(),
                    existingClusters: store.listSpeakerClusters(meetingId: meetingId),
                    attendeePersonIDs: Set(store.listPeopleForMeeting(meetingId: meetingId).map(\.id)))
                try store.saveSpeakerClusters(identified.clusters)
                try store.saveUtterances(identified.utterances)
            }
            try store.saveMeeting(latest)
            updated = latest
        }
        guard let updated else { throw CocoaError(.fileWriteUnknown) }
        return updated
    }

    private func summarySnapshot(_ value: MeetingSummary?) throws -> Data? {
        guard let value else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    public func generateCurrentSummary() async {
        guard !isSummarizing, let meeting = currentMeeting else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let utterances = currentUtterances
        let attendees = currentAttendees
        let template = summaryTemplate
        let apple = summaryUsesAppleIntelligence
        statusMessage = apple ? "Generating notes with Apple's on-device model…" : "Extracting notes from the transcript…"
        do {
            let baseline = try summarySnapshot(store.getSummary(meetingId: meeting.id))
            let summary = try await summarizeMeeting(meeting, utterances, attendees, template, apple)
            try store.withImmediateTransaction {
                guard try summarySnapshot(store.getSummary(meetingId: meeting.id)) == baseline else {
                    throw NSError(domain: "MinutesApp", code: 409, userInfo: [NSLocalizedDescriptionKey: "The summary changed while generation was running. Your edits were preserved; review them before generating again."])
                }
                try store.saveSummary(summary)
            }
            if currentMeeting?.id == meeting.id { currentSummary = summary }
            await automaticallyFileMeeting(id: meeting.id)
            statusMessage = Summarizer.hasOnlyIntroductions(utterances: utterances, userNotes: meeting.userNotes)
                ? summary.overview
                : (apple ? "On-device AI draft saved. Review it before sharing." : "Transcript highlights saved. No AI summary was generated.")
        } catch { statusMessage = "Summary failed: \(error.localizedDescription) Your existing notes and transcript are preserved." }
    }

    private func configuredPrismConnection() throws -> PrismConnection {
        if let prismConnection { return prismConnection }
        guard let origin = URL(string: prismOrigin) else { throw PrismConnectionError.invalidOrigin }
        let connection = try PrismConnection(origin: origin, store: store)
        prismConnection = connection
        return connection
    }
    /// Resume a stored native grant; never opens a browser or sends an email.
    public func restorePrismConnection() async {
        guard !prismBusy, !restoringPrism else { return }
        restoringPrism = true
        defer { restoringPrism = false }
        prismBusy = true
        prismOperation += 1; let operation = prismOperation
        defer { if prismOperation == operation { prismBusy = false } }
        do {
            let connection = try configuredPrismConnection()
            let saved = try await connection.status(allowInteraction: false)
            guard operation == prismOperation, !Task.isCancelled else { return }
            guard saved.hasCredential else {
                prismVerified = false
                prismMessage = "Connect Prism to choose a vault. Local meetings stay on this device."
                return
            }
            prismMessage = "Reconnecting to your saved Prism vault…"
            try await acceptPrismCapabilities(from: connection, operation: operation)
        } catch {
            guard operation == prismOperation else { return }
            prismVerified = false
            prismMessage = "Saved Prism connection is unavailable: \(error.localizedDescription) Choose Verify to retry or Connect to sign in again."
        }
    }
    public func cancelPrismAuthorization() {
        guard prismAuthorizationPending else { return }
        prismOperation += 1
        prismAuthorizationTask?.cancel(); prismAuthorizationTask = nil
        prismAuthorizationPending = false; prismBusy = false
        prismMessage = "Prism sign-in cancelled. Your local meetings are unchanged."
    }

    public func connectPrism(using browser: any PrismBrowserAuthorizing = OAuthSystemBrowserSession()) async {
        guard !prismBusy else { return }
        prismBusy = true; prismVerified = false; prismAuthorizationPending = true
        prismOperation += 1; let operation = prismOperation
        defer {
            if operation == prismOperation { prismBusy = false; prismAuthorizationPending = false; prismAuthorizationTask = nil }
        }
        do {
            let connection = try configuredPrismConnection()
            prismMessage = "Finish sign-in in the system browser, then approve one vault. If you use an email link, open it in Safari on this device and return to the sign-in window."
            let authorization = Task { try await connection.connect(using: browser, label: "Minutes") }
            prismAuthorizationTask = authorization
            try await withTaskCancellationHandler { try await authorization.value } onCancel: { authorization.cancel() }
            guard operation == prismOperation, !Task.isCancelled else { return }
            try await acceptPrismCapabilities(from: connection, operation: operation)
        } catch {
            guard operation == prismOperation else { return }
            prismMessage = "Prism sign-in failed: \(error.localizedDescription)"
        }
    }
    public func verifyPrism() async {
        guard !prismBusy else { return }
        prismBusy = true; prismVerified = false
        defer { prismBusy = false }
        do { try await acceptPrismCapabilities(from: configuredPrismConnection()) }
        catch { prismMessage = "Prism is not ready: \(error.localizedDescription)" }
    }
    private func acceptPrismCapabilities(from connection: PrismConnection, operation: Int? = nil) async throws {
        let capabilities = try await connection.verifyCapabilities()
        guard prismConnection?.origin == connection.origin, operation == nil || operation == prismOperation, !Task.isCancelled else { throw OAuthError.cancelled }
        prismVaults = capabilities.vaults; prismVerified = true
        if !prismVaults.contains(where: { $0.id == prismVaultID }) { prismVaultID = prismVaults.first?.id ?? "" }
        prismMessage = "Connected to Prism with restricted Minutes access."
        prismOutbox = await connection.outboxItems(includeSynced: true)
    }
    public func disconnectPrism() async {
        guard !prismBusy else { return }
        prismBusy = true
        defer { prismBusy = false; prismVerified = false; prismConnection = nil; prismVaults = []; prismOutbox = [] }
        do { try await configuredPrismConnection().disconnect(); prismMessage = "Prism disconnected. Local meetings and queued payloads are preserved." }
        catch { prismMessage = "Disconnected locally; remote revocation was not confirmed: \(error.localizedDescription)" }
    }
    public func syncPrismOutbox() async {
        guard !prismBusy else { return }
        prismBusy = true
        defer { prismBusy = false }
        do {
            let connection = try configuredPrismConnection()
            _ = try await connection.syncPending()
            prismOutbox = await connection.outboxItems(includeSynced: true)
            let remaining = prismOutbox.filter { $0.status != .synced && $0.status != .revoked }.count
            prismMessage = remaining == 0 ? "All queued meetings have committed receipts." : "\(remaining) deliveries need attention."
        } catch { prismVerified = false; prismMessage = "Sync paused: \(error.localizedDescription)" }
    }
    public func cancelPrismDelivery(id: String) async {
        do { let connection = try configuredPrismConnection(); try await connection.cancelItem(id: id); prismOutbox = await connection.outboxItems(includeSynced: true) }
        catch { prismMessage = "Could not cancel delivery: \(error.localizedDescription)" }
    }
    private func sendToPrism(_ bundle: MeetingExportBundle) async throws -> ExportResult {
        let connection = try configuredPrismConnection()
        if !prismVerified { try await acceptPrismCapabilities(from: connection) }
        let item = try await connection.enqueueNextRevision(bundle: bundle, destinationVault: prismVaultID)
        prismOutbox = await connection.outboxItems(includeSynced: true)
        statusMessage = "Queued meeting for Prism. Waiting for a committed receipt…"
        _ = try await connection.syncPending()
        prismOutbox = await connection.outboxItems(includeSynced: true)
        guard let completed = prismOutbox.first(where: { $0.id == item.id }), completed.status == .synced, let receipt = completed.receipt else {
            throw PrismError.failedRetryable(statusCode: 0, message: "Meeting is queued; no committed receipt yet. Review deliveries in Settings.")
        }
        return ExportResult(adapterId: "prism", externalRef: receipt.meetingNoteId, success: true)
    }

    public func exportCurrentMeeting(target: String) async -> ExportResult {
        guard let meeting = currentMeeting else {
            return ExportResult(adapterId: target, success: false, error: "No active meeting selected")
        }
        
        let bundle = MeetingExportBundle(
            meeting: meeting,
            attendees: currentAttendees,
            clusters: currentClusters,
            utterances: currentUtterances,
            summary: currentSummary
        )
        
        do {
            let result: ExportResult
            switch target {
            case "markdown":
                result = try await MarkdownAdapter(outputDirectory: markdownDirectory).export(bundle: bundle)
            case "parachute", "prism":
                result = try await sendToPrism(bundle)
            case "legacy-parachute":
                result = try await ParachuteAdapter(vaultHost: parachuteHost).export(bundle: bundle)
            default:
                return ExportResult(adapterId: target, success: false, error: "Unknown export destination: \(target)")
            }
            statusMessage = result.success ? "Exported meeting via \(target)." : "Export failed: \(result.error ?? "No receipt returned")"
            return result
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            return ExportResult(adapterId: target, success: false, error: error.localizedDescription)
        }
    }

}
#endif
