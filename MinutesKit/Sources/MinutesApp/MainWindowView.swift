#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSummarize
import MinutesUI
import MinutesExport

@available(macOS 15.0, iOS 18.0, *)
public struct MainWindowView: View {
    @ObservedObject public var appState: AppState
    @State private var meetingTab: MeetingTab = .speakers
    
    public enum MeetingTab: String, CaseIterable, Identifiable {
        case speakers = "Speaker Review"
        case transcript = "Transcript"
        case summary = "AI Summary"
        
        public var id: String { rawValue }
    }
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(MinutesTheme.bg)
    }
    
    // MARK: - Sidebar
    
    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand Logo in Sidebar
            HStack(spacing: 10) {
                Text("M")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(
                            colors: [MinutesTheme.primary, MinutesTheme.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Minutes")
                        .font(.headline)
                        .foregroundStyle(MinutesTheme.text)
                    Text("LOCAL-FIRST")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(MinutesTheme.primary)
                }
            }
            .padding(16)
            
            Divider()
                .overlay(MinutesTheme.border)
            
            // Navigation Sections List
            List(NavigationSection.allCases, selection: $appState.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 4)
                    .tag(section)
            }
            .listStyle(.sidebar)
            
            Spacer()
            
            // System Status Footnote
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MinutesTheme.emerald)
                        .frame(width: 6, height: 6)
                    Text("FluidAudio Parakeet Ultra")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MinutesTheme.muted)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(MinutesTheme.emerald)
                        .frame(width: 6, height: 6)
                    Text("Parachute (localhost:1940)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MinutesTheme.muted)
                }
            }
            .padding(14)
            .background(MinutesTheme.cardHover)
        }
        .frame(minWidth: 200, idealWidth: 220)
        .background(MinutesTheme.card)
    }
    
    // MARK: - Detail Content
    
    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedSection {
        case .meetings:
            meetingsMasterDetailView
        case .liveIngestion:
            LiveIngestionView(appState: appState)
        case .voiceprintHub:
            VoiceprintHubView(
                store: appState.store,
                meetingId: appState.selectedMeetingId,
                voiceprints: appState.voiceprints,
                people: appState.currentAttendees,
                clusters: appState.currentClusters,
                utterances: appState.currentUtterances
            )
        case .onboarding:
            OnboardingView(
                permissionManager: appState.permissionManager,
                onComplete: {
                    appState.selectedSection = .meetings
                }
            )
        case .settings:
            SettingsView(appState: appState)
        }
    }
    
    // MARK: - Meetings View (Master-Detail)
    
    private var meetingsMasterDetailView: some View {
        HStack(spacing: 0) {
            // Meetings List Column
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Meetings (\(appState.meetings.count))")
                        .font(.headline)
                        .foregroundStyle(MinutesTheme.text)
                    Spacer()
                    Button(action: { appState.selectedSection = .liveIngestion }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(MinutesTheme.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(MinutesTheme.card)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(MinutesTheme.border),
                    alignment: .bottom
                )
                
                List(appState.meetings, selection: $appState.selectedMeetingId) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(MinutesTheme.text)
                            .lineLimit(1)
                        
                        HStack {
                            Text(DateFormatter.localizedString(from: meeting.startedAt, dateStyle: .short, timeStyle: .short))
                                .font(.caption2)
                                .foregroundStyle(MinutesTheme.muted)
                            Spacer()
                            Text(meeting.status.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(statusColor(meeting.status).opacity(0.15))
                                .foregroundStyle(statusColor(meeting.status))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(meeting.id)
                }
                .listStyle(.plain)
                .onChange(of: appState.selectedMeetingId) { _, newId in
                    appState.selectMeeting(id: newId)
                }
            }
            .frame(width: 260)
            .background(MinutesTheme.card)
            .overlay(
                Rectangle()
                    .frame(width: 1)
                    .foregroundStyle(MinutesTheme.border),
                alignment: .trailing
            )
            
            // Meeting Detail Panels
            VStack(spacing: 0) {
                if let meeting = appState.currentMeeting {
                    // Meeting Header Bar
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(.title3.bold())
                                    .foregroundStyle(MinutesTheme.text)
                                Text("📅 \(DateFormatter.localizedString(from: meeting.startedAt, dateStyle: .medium, timeStyle: .short)) · \(appState.currentUtterances.count) utterances · \(appState.currentClusters.count) speakers")
                                    .font(.caption)
                                    .foregroundStyle(MinutesTheme.muted)
                            }
                            Spacer()
                            
                            // Segmented Tabs
                            Picker("", selection: $meetingTab) {
                                ForEach(MeetingTab.allCases) { tab in
                                    Text(tab.rawValue).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 320)
                        }
                    }
                    .padding(14)
                    .background(MinutesTheme.card)
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundStyle(MinutesTheme.border),
                        alignment: .bottom
                    )
                    
                    // Tab Content
                    switch meetingTab {
                    case .speakers:
                        ReviewSpeakersView(
                            meeting: meeting,
                            clusters: appState.currentClusters,
                            attendees: appState.currentAttendees,
                            voiceprints: appState.voiceprints,
                            diarizationConfig: appState.diarizationConfig,
                            onAssign: { clusterId, person in
                                if let idx = appState.currentClusters.firstIndex(where: { $0.id == clusterId }) {
                                    appState.currentClusters[idx].label = person.displayName
                                    appState.currentClusters[idx].personId = person.id
                                    appState.currentClusters[idx].assignment = "user"
                                    try? appState.store.saveSpeakerClusters(appState.currentClusters)
                                }
                            },
                            onLockAndEnroll: { updatedClusters in
                                for c in updatedClusters where !c.centroid.isEmpty {
                                    if let pId = c.personId {
                                        let vp = Voiceprint(personId: pId, vector: c.centroid, speechSeconds: c.speechSeconds)
                                        try? appState.store.saveVoiceprint(vp)
                                    }
                                }
                                try? appState.store.saveSpeakerClusters(updatedClusters)
                                appState.voiceprints = appState.store.listVoiceprints()
                            },
                            onApplyDiarizationConfig: { newConfig in
                                appState.diarizationConfig = newConfig
                            }
                        )
                    case .transcript:
                        TranscriptView(
                            utterances: appState.currentUtterances,
                            availableSpeakers: appState.currentClusters.map { $0.label },
                            onUtteranceEdited: { edited in
                                try? appState.store.saveUtterances([edited])
                            },
                            onSpeakerReassigned: { uId, newSpeaker in
                                if let idx = appState.currentUtterances.firstIndex(where: { $0.id == uId }) {
                                    appState.currentUtterances[idx].speakerName = newSpeaker
                                    try? appState.store.saveUtterances([appState.currentUtterances[idx]])
                                }
                            },
                            onExportParachute: {
                                Task {
                                    _ = await appState.exportCurrentMeeting(target: "parachute")
                                }
                            },
                            onExportMarkdown: {
                                Task {
                                    _ = await appState.exportCurrentMeeting(target: "markdown")
                                }
                            }
                        )
                    case .summary:
                        if let summary = appState.currentSummary {
                            SummaryView(
                                summary: summary,
                                onExportParachute: {
                                    Task {
                                        _ = await appState.exportCurrentMeeting(target: "parachute")
                                    }
                                },
                                onExportMarkdown: {
                                    Task {
                                        _ = await appState.exportCurrentMeeting(target: "markdown")
                                    }
                                }
                            )
                        } else {
                            VStack(spacing: 12) {
                                Text("No summary generated for this meeting yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.muted)
                                Button("Generate AI Summary") {
                                    Task {
                                        let s = Summarizer()
                                        let sum = try? await s.summarize(
                                            meeting: meeting,
                                            utterances: appState.currentUtterances,
                                            attendees: appState.currentAttendees
                                        )
                                        if let sum = sum {
                                            try? appState.store.saveSummary(sum)
                                            appState.currentSummary = sum
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(MinutesTheme.primary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundStyle(MinutesTheme.muted)
                        Text("Select a meeting from the list or start a new recording.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "recorded": return Color.blue
        case "needs_review": return Color.orange
        case "summarized", "finalized": return MinutesTheme.emerald
        default: return MinutesTheme.muted
        }
    }
}
#endif
