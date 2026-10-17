#if canImport(SwiftUI)
import SwiftUI
import MinutesUI

struct UpcomingMeetingsView: View {
    @ObservedObject var appState: AppState
    var onOpenSettings: (() -> Void)? = nil
    @State private var connectingApple = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        CalendarAgendaView(events: appState.upcomingEvents, sourceName: appState.calendarSource.rawValue,
            isConnected: appState.calendarConnected, isRefreshing: appState.googleRefreshing,
            isConnecting: appState.googleConnecting || connectingApple, statusMessage: appState.calendarSource == .google ? appState.googleMessage : appState.calendarMessage,
            recordingUnavailableReason: recordingUnavailableReason,
            onRefresh: { appState.refreshCalendar() },
            onConnect: {
                connectingApple = true
                Task { await appState.connectCalendar(); connectingApple = false }
            },
            onOpenSettings: {
                if let onOpenSettings { onOpenSettings() }
                else {
                    #if os(macOS)
                    openSettings()
                    #else
                    appState.selectedSection = .settings
                    #endif
                }
            },
            onRecord: { event in
                Task { if await appState.prepareRecording() { appState.startQuickMeeting(event: event) } }
            }, notificationsEnabled: appState.calendarNotificationsEnabled,
            onEnableNotifications: { Task { await appState.enableCalendarNotifications() } })
            .navigationTitle("Calendar")
            .onAppear { appState.refreshSpeechReadiness() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in appState.refreshCalendar() }
    }

    private var recordingUnavailableReason: String? {
        if appState.isRecording { return "A recording is already in progress." }
        if appState.isStartingRecording || appState.isPreparingRecording { return "Preparing a recording. Please wait." }
        if appState.isFinalizingRecording || appState.isProcessing { return "Finish saving and processing the current recording first." }
        if appState.isSettingUpSpeechModels { return "Speech models are being installed. Recording will be available after setup." }
        if !appState.recordingModelsReady { return "Set up local speech models in Settings before recording." }
        return nil
    }
}
#endif
