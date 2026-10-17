import SwiftUI
import MinutesUI

struct IOSRecordingNote: View {
    @ObservedObject var state: AppState
    @State private var lastMeetingID: String?

    var body: some View {
        Group {
            if let id = state.activeRecordingMeetingID ?? lastMeetingID {
                IOSMeetingDetail(state: state, meetingID: id, showsRecording: true).id(id)
            } else {
                ScrollView {
                    IOSRecordingWorkspace(state: state).padding(24)
                }
                .navigationTitle("New Recording")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: state.activeRecordingMeetingID, initial: true) { _, id in
            if let id { lastMeetingID = id }
        }
    }
}

struct IOSRecordingWorkspace: View {
    @ObservedObject var state: AppState
    var body: some View {
        RecordingWorkspaceView(isRecording: state.isRecording,
            isBusy: state.isStartingRecording || state.isFinalizingRecording || state.isProcessing || state.isPreparingRecording,
            busyMessage: state.isProcessing ? "Processing Saved Audio…" : (state.isFinalizingRecording ? "Finalizing Recording…" : (state.isStartingRecording ? "Starting Recording…" : "Checking Recording Permissions…")),
            canStart: state.canStartRecording, modelsReady: state.recordingModelsReady,
            isInstalling: state.isSettingUpSpeechModels, readinessMessage: state.speechModelStatus,
            statusMessage: state.statusMessage, meter: state.recordingMeter,
            source: Binding(get: { state.captureMode.rawValue }, set: { _ in }),
            sources: [AppState.CaptureMode.microphone.rawValue],
            onInstall: { Task { await state.setupSpeechModels() } },
            onStart: { Task { if await state.prepareRecording() { state.startQuickMeeting() } } },
            onStop: { Task { await state.stopAndProcessMeeting() } })
        .onAppear { state.refreshSpeechReadiness() }
    }
}
