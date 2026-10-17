#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesUI

/// Kept for secondary entry points; the main window presents these controls inline.
@available(macOS 15.0, iOS 18.0, *)
public struct LiveIngestionView: View {
    @ObservedObject public var appState: AppState
    public init(appState: AppState) { self.appState = appState }
    public var body: some View {
        RecordingWorkspaceView(isRecording: appState.isRecording,
            isBusy: appState.isStartingRecording || appState.isFinalizingRecording || appState.isProcessing || appState.isPreparingRecording,
            busyMessage: appState.isProcessing ? "Processing Saved Audio…" : (appState.isFinalizingRecording ? "Finalizing Recording…" : (appState.isStartingRecording ? "Starting Recording…" : "Checking Recording Permissions…")),
            canStart: appState.canStartRecording, modelsReady: appState.recordingModelsReady,
            isInstalling: appState.isSettingUpSpeechModels, readinessMessage: appState.speechModelStatus,
            statusMessage: appState.statusMessage, meter: appState.recordingMeter,
            source: Binding(get: { appState.captureMode.rawValue }, set: { if let source = AppState.CaptureMode(rawValue: $0) { appState.captureMode = source } }),
            sources: availableSources,
            onInstall: { Task { await appState.setupSpeechModels() } },
            onStart: { Task { if await appState.prepareRecording() { appState.startQuickMeeting() } } },
            onStop: { Task { await appState.stopAndProcessMeeting() } })
        .padding(.vertical, 8)
        .onAppear { appState.refreshSpeechReadiness() }
    }
    private var availableSources: [String] {
        #if os(macOS)
        AppState.CaptureMode.allCases.map(\.rawValue)
        #else
        [AppState.CaptureMode.microphone.rawValue]
        #endif
    }
}
#endif
