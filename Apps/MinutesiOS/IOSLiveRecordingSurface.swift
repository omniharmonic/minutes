import Combine
import Foundation
import UIKit
import MinutesActivity
import MinutesUI

/// Glue between AppState and the recording surfaces outside the main screen:
/// the Live Activity (Lock Screen / Dynamic Island) and optional live captions.
/// It observes AppState instead of changing it, and its buttons call the same
/// AppState actions as the in-app Stop and Moment buttons.
@MainActor
final class IOSLiveRecordingSurface {
    let captions: LiveCaptionSessionModel
    private let state: AppState
    private let activity = RecordingLiveActivityController()
    private var subscriptions: Set<AnyCancellable> = []
    private var recordingMeetingID: String?

    init(state: AppState, captions: LiveCaptionSessionModel = LiveCaptionSessionModel()) {
        self.state = state
        self.captions = captions
        // Anything still showing is from an earlier process that ended abruptly.
        activity.endExisting()
        registerCommands()
        observe()
    }

    private func registerCommands() {
        let commands = RecordingActivityCommands.shared
        commands.stopRecording = { [weak self] in
            guard let self else { return }
            guard self.state.isRecording else { self.activity.end(); self.activity.endExisting(); return }
            // Same path as the in-app Stop button. Processing continues after
            // the intent returns; the recording itself stops right away.
            let state = self.state
            Task { await state.stopAndProcessMeeting() }
        }
        commands.markMoment = { [weak self] in
            guard let self, self.state.isRecording else { return }
            self.state.markRecordingMoment()
        }
        commands.endStaleActivities = { [weak self] in self?.activity.endExisting() }
    }

    private func observe() {
        // @Published emits on willSet, so use the emitted value, not the property.
        state.$isRecording.removeDuplicates().sink { [weak self] recording in
            guard let self else { return }
            if recording { self.recordingStarted() } else { self.recordingEnded() }
        }.store(in: &subscriptions)

        state.recordingMeter.$snapshot.sink { [weak self] snapshot in
            guard let self, self.recordingMeetingID != nil else { return }
            self.activity.update(title: self.title, duration: snapshot.duration, level: snapshot.level,
                                 caption: self.captions.isEnabled ? self.captions.latestText : nil)
        }.store(in: &subscriptions)

        captions.$isEnabled.removeDuplicates().sink { [weak self] enabled in
            guard let self, enabled, self.recordingMeetingID != nil else { return }
            // Turned on mid-recording: begin after the property has been set.
            Task { @MainActor in self.captions.begin() }
        }.store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification).sink { [weak self] _ in
            self?.terminate()
        }.store(in: &subscriptions)
    }

    private var title: String {
        guard let id = recordingMeetingID ?? state.activeRecordingMeetingID else { return "Recording" }
        return state.meetings.first { $0.id == id }?.title ?? state.currentMeeting.flatMap { $0.id == id ? $0.title : nil } ?? "Recording"
    }

    private func recordingStarted() {
        guard let id = state.activeRecordingMeetingID else { return }
        recordingMeetingID = id
        activity.begin(meetingID: id, title: title, startedAt: Date())
        captions.begin()
    }

    private func recordingEnded() {
        guard recordingMeetingID != nil else { return }
        let title = self.title
        recordingMeetingID = nil
        captions.finish()
        activity.finish(title: title, duration: state.recordingMeter.duration)
    }

    private func terminate() {
        captions.stop()
        activity.end()
        // Give ActivityKit a brief, bounded chance to dismiss before exit.
        let done = DispatchSemaphore(value: 0)
        Task.detached { await RecordingLiveActivityController.endAll(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }
}
