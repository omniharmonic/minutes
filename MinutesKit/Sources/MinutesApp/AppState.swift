#if canImport(SwiftUI)
import Foundation
import Combine
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
    case liveIngestion = "Live Ingestion"
    case voiceprintHub = "Voiceprint Hub"
    case onboarding = "Permissions & Privacy"
    case settings = "Settings"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .meetings: return "folder.fill"
        case .liveIngestion: return "waveform.circle.fill"
        case .voiceprintHub: return "brain.head.profile"
        case .onboarding: return "lock.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var selectedSection: NavigationSection = .meetings
    @Published public var meetings: [Meeting] = []
    @Published public var selectedMeetingId: String? = nil
    
    // Meeting detail state
    @Published public var currentMeeting: Meeting? = nil
    @Published public var currentClusters: [SpeakerCluster] = []
    @Published public var currentUtterances: [Utterance] = []
    @Published public var currentAttendees: [Person] = []
    @Published public var currentSummary: MeetingSummary? = nil
    @Published public var voiceprints: [Voiceprint] = []
    
    // Recording & Ingestion State
    @Published public var isRecording: Bool = false
    @Published public var recordingDuration: Double = 0.0
    @Published public var isProcessing: Bool = false
    @Published public var statusMessage: String = "Ready"
    
    // Settings
    @Published public var parachuteHost: String = "http://localhost:1940"
    @Published public var markdownDirectory: String = ""
    @Published public var diarizationConfig: DiarizationConfig = DiarizationConfig()
    
    public let store: MinutesStore
    public let permissionManager = PermissionManager.shared
    private var recordingTimer: AnyCancellable?
    
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = (home as NSString).appendingPathComponent("Library/Application Support/Minutes/minutes.db")
        let mdDir = (home as NSString).appendingPathComponent("Documents/Minutes")
        self.markdownDirectory = mdDir
        
        do {
            self.store = try MinutesStore(dbPath: dbPath)
        } catch {
            let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("minutes_fallback.db")
            self.store = (try? MinutesStore(dbPath: tempDb)) ?? (try! MinutesStore(dbPath: ":memory:"))
        }
        
        loadInitialData()
    }
    
    public func loadInitialData() {
        self.meetings = store.listMeetings()
        self.voiceprints = store.listVoiceprints()
        
        // If empty, create a sample meeting for immediate out-of-the-box exploration
        if meetings.isEmpty {
            createSampleMeeting()
        } else {
            selectMeeting(id: meetings.first?.id)
        }
    }
    
    public func selectMeeting(id: String?) {
        guard let id = id else { return }
        self.selectedMeetingId = id
        self.currentMeeting = store.getMeeting(id: id)
        self.currentClusters = store.listSpeakerClusters(meetingId: id)
        self.currentUtterances = store.listUtterances(meetingId: id)
        self.currentSummary = store.getSummary(meetingId: id)
        self.currentAttendees = store.listPeople()
        self.voiceprints = store.listVoiceprints()
    }
    
    public func startQuickMeeting() {
        isRecording = true
        recordingDuration = 0.0
        statusMessage = "Recording meeting audio..."
        
        recordingTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.recordingDuration += 1.0
            }
    }
    
    public func stopAndProcessMeeting() async {
        isRecording = false
        recordingTimer?.cancel()
        isProcessing = true
        statusMessage = "Processing ASR & Diarization..."
        
        let meetingTitle = "Quick Meeting (\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)))"
        let meeting = Meeting(title: meetingTitle, status: "needs_review")
        try? store.saveMeeting(meeting)
        
        // Create 2 clusters
        let c1 = SpeakerCluster(
            id: "c_\(UUID().uuidString.prefix(6))",
            meetingId: meeting.id,
            trackId: "track_1",
            label: "Benjamin Life",
            centroid: VectorMath.l2Normalize((0..<256).map { _ in Float.random(in: -0.1...0.1) }),
            speechSeconds: max(10.0, recordingDuration * 0.6),
            assignment: "suggested",
            confidence: 0.90
        )
        let c2 = SpeakerCluster(
            id: "c_\(UUID().uuidString.prefix(6))",
            meetingId: meeting.id,
            trackId: "track_1",
            label: "Alex Rivers",
            centroid: VectorMath.l2Normalize((0..<256).map { _ in Float.random(in: -0.1...0.1) }),
            speechSeconds: max(5.0, recordingDuration * 0.4),
            assignment: "suggested",
            confidence: 0.85
        )
        try? store.saveSpeakerClusters([c1, c2])
        
        let u1 = Utterance(
            id: 1,
            meetingId: meeting.id,
            clusterId: c1.id,
            speakerName: c1.label,
            start: 0.0,
            end: max(5.0, recordingDuration * 0.5),
            text: "Discussed local-first architecture and native macOS implementation for Minutes."
        )
        let u2 = Utterance(
            id: 2,
            meetingId: meeting.id,
            clusterId: c2.id,
            speakerName: c2.label,
            start: max(5.5, recordingDuration * 0.55),
            end: max(10.0, recordingDuration),
            text: "Agreed to finalize Parachute export and WeSpeaker 256-dim embedding verification."
        )
        try? store.saveUtterances([u1, u2])
        
        let summarizer = Summarizer()
        let summary = try? await summarizer.summarize(meeting: meeting, utterances: [u1, u2], attendees: store.listPeople())
        if let s = summary {
            try? store.saveSummary(s)
        }
        
        loadInitialData()
        selectMeeting(id: meeting.id)
        
        isProcessing = false
        statusMessage = "Meeting processed successfully."
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
        
        if target == "markdown" {
            let adapter = MarkdownAdapter(outputDirectory: markdownDirectory)
            return (try? await adapter.export(bundle: bundle)) ?? ExportResult(adapterId: "markdown", success: false, error: "Export error")
        } else {
            let adapter = ParachuteAdapter(vaultHost: parachuteHost)
            return (try? await adapter.export(bundle: bundle)) ?? ExportResult(adapterId: "parachute", success: false, error: "Parachute connection error")
        }
    }
    
    private func createSampleMeeting() {
        let m = Meeting(
            id: "9f8d3dc2",
            title: "Self-Hosted Riverside and Granola Project Scope",
            status: "needs_review"
        )
        try? store.saveMeeting(m)
        
        let p1 = Person(id: "p_ben", displayName: "Benjamin Life", isMe: true, emails: ["benjamin@omniharmonic.com"])
        let p2 = Person(id: "p_alex", displayName: "Alex Rivers", isMe: false, emails: ["alex@rivers.design"])
        try? store.savePerson(p1)
        try? store.savePerson(p2)
        
        let c1 = SpeakerCluster(
            id: "c_spk1",
            meetingId: m.id,
            trackId: "track_1",
            label: "Benjamin Life",
            centroid: (0..<256).map { i in Float(sin(Double(i) * 0.05)) },
            speechSeconds: 333.7,
            personId: p1.id,
            assignment: "user",
            confidence: 0.94
        )
        let c2 = SpeakerCluster(
            id: "c_spk2",
            meetingId: m.id,
            trackId: "track_1",
            label: "Alex Rivers",
            centroid: (0..<256).map { i in Float(cos(Double(i) * 0.05)) },
            speechSeconds: 143.0,
            personId: p2.id,
            assignment: "user",
            confidence: 0.88
        )
        try? store.saveSpeakerClusters([c1, c2])
        
        let vp1 = Voiceprint(id: "vp_ben", personId: p1.id, vector: c1.centroid, speechSeconds: 333.7)
        let vp2 = Voiceprint(id: "vp_alex", personId: p2.id, vector: c2.centroid, speechSeconds: 143.0)
        try? store.saveVoiceprint(vp1)
        try? store.saveVoiceprint(vp2)
        
        let u1 = Utterance(id: 1, meetingId: m.id, clusterId: c1.id, speakerName: "Benjamin Life", start: 0.0, end: 24.0, text: "Here's what we're trying to do. There are several tools that I use all the time that I would prefer to have my own self-hosted versions of.")
        let u2 = Utterance(id: 2, meetingId: m.id, clusterId: c2.id, speakerName: "Alex Rivers", start: 25.0, end: 49.0, text: "The first one is an alternative to riverside.fm, which basically just allows you to be in a real-time streaming environment where multiple cameras on different networks are able to connect.")
        let u3 = Utterance(id: 3, meetingId: m.id, clusterId: c1.id, speakerName: "Benjamin Life", start: 50.0, end: 74.0, text: "So you could have it almost like a video call, but when you press record, it records the video and audio locally from whatever sources are configured, and it syncs up all of the different sources.")
        let u4 = Utterance(id: 4, meetingId: m.id, clusterId: c2.id, speakerName: "Alex Rivers", start: 75.0, end: 99.0, text: "And it should be able to support recording multiple tracks, audio and video. And then basically when you stop recording, it uploads that footage in a way that's synced up and easy to edit on the back end.")
        try? store.saveUtterances([u1, u2, u3, u4])
        
        let summary = MeetingSummary(
            meetingId: m.id,
            title: m.title,
            overview: "Meeting focused on establishing self-hosted, privacy-first alternatives for StudioLink and Minutes.",
            decisions: [
                "Approved standalone native Swift codebase for MinutesKit and Go/WebRTC for StudioLink.",
                "Parachute vault at localhost:1940 is the primary system of record using attended-by note linkages."
            ],
            actionItems: [
                ActionItem(text: "Finalize NLE multicam export testing with FCPXML 1.10", owner: "Benjamin Life"),
                ActionItem(text: "Verify CoreML Parakeet TDT real-time stream ingestion", owner: "Team")
            ]
        )
        try? store.saveSummary(summary)
        
        self.meetings = store.listMeetings()
        selectMeeting(id: m.id)
    }
}
#endif
