import BackgroundTasks
import Combine
import UIKit
import os

/// Keeps a transcription or summary running after the person leaves the app.
/// On iOS 26 and later this is a continued-processing task, which the system
/// shows with live progress; earlier systems get the short standard grace
/// period. Either way the job resumes where it was if iOS suspends it.
@MainActor
final class ContinuedProcessing {
    private static let logger = Logger(subsystem: "app.minutes", category: "ContinuedProcessing")
    /// Matches BGTaskSchedulerPermittedIdentifiers in Apps/project.yml.
    private static let identifierPrefix = "app.minutes.ios.processing."

    private let state: AppState
    private var progress: AnyCancellable?
    private var requestID: String?
    private var task: BGTask?
    private var graceTask: UIBackgroundTaskIdentifier = .invalid

    init(state: AppState) { self.state = state }

    /// Call whenever the app's "a job is running" state changes.
    func busyChanged(_ busy: Bool) {
        if busy { begin() } else { finish(success: true) }
    }

    private func begin() {
        guard requestID == nil, graceTask == .invalid else { return }
        if #available(iOS 26, *), submitContinuedTask() { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "Process meeting") { [weak self] in
            self?.endGrace()
        }
    }

    @available(iOS 26, *)
    private func submitContinuedTask() -> Bool {
        let id = Self.identifierPrefix + UUID().uuidString
        // Each identifier is registered once; continued tasks may register after launch.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.started(task) }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Processing meeting", subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            requestID = id
            return true
        } catch {
            Self.logger.info("Continued processing unavailable: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @available(iOS 26, *)
    private func started(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, requestID != nil else {
            task.setTaskCompleted(success: true)  // the job already finished
            return
        }
        self.task = task
        task.progress.totalUnitCount = 1_000
        task.expirationHandler = { [weak self] in
            // iOS ended the grant (the person stopped it, or the system needed
            // resources). The job pauses and continues when the app is active.
            Task { @MainActor in self?.finish(success: false) }
        }
        progress = state.$processingProgress.combineLatest(state.$processingPhase)
            .receive(on: RunLoop.main)
            .sink { [weak task] fraction, phase in
                guard let task, let fraction else { return }
                task.progress.completedUnitCount = Int64((fraction * 1_000).rounded(.down))
                if !phase.isEmpty { task.updateTitle("Processing meeting", subtitle: phase) }
            }
    }

    private func finish(success: Bool) {
        progress = nil
        if let task { task.setTaskCompleted(success: success) }
        else if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        task = nil
        requestID = nil
        endGrace()
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }
}
