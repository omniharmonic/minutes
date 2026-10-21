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
        VStack(alignment: .leading, spacing: 18) {
            controls
            if state.isRecording { IOSLiveCaptionsSection() }
        }
        .onAppear { state.refreshSpeechReadiness() }
    }
    private var controls: some View {
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
            onStop: { Task { await state.stopAndProcessMeeting() } },
            moments: state.recordingBookmarks,
            onMarkMoment: { state.markRecordingMoment() },
            onRenameMoment: { state.renameBookmark($0, to: $1) },
            onRemoveMoment: { state.deleteBookmark($0) })
    }
}

/// Observes captions on its own so frequent caption updates redraw only this.
private struct IOSLiveCaptionsSection: View {
    @EnvironmentObject private var captions: LiveCaptionSessionModel
    var body: some View {
        if captions.isEnabled {
            LiveCaptionScrollView(history: captions.history, status: captions.status, isListening: captions.isRunning)
        }
    }
}

/// Settings row for optional on-device live captions.
struct IOSLiveCaptionSetting: View {
    @EnvironmentObject private var captions: LiveCaptionSessionModel
    var body: some View {
        Section {
            Toggle("Live captions while recording", isOn: $captions.isEnabled)
            if !captions.isEnabled, let problem = captions.availabilityProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Live captions") } footer: {
            Text("Shows a local preview of what is said, in the app and on the Lock Screen. Recognition runs only on this iPhone and audio is never sent anywhere. Captions are discarded; the saved transcript is made separately from the recording.")
        }
        .onChange(of: captions.isEnabled) { _, enabled in
            if enabled { Task { await captions.confirmAvailability() } }
        }
    }
}
