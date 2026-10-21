#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation
import os

/// Owns at most one recording Live Activity. Callers feed meter ticks freely;
/// the composer throttles ActivityKit updates to about once per second and
/// only when something visible changed.
///
/// `Activity` is not Sendable, so the controller keeps only the activity's ID
/// and every ActivityKit call looks the activity up inside a nonisolated helper.
@MainActor public final class RecordingLiveActivityController {
    public typealias State = RecordingActivityAttributes.ContentState
    private static let log = Logger(subsystem: "app.minutes", category: "liveactivity")
    private var activityID: String?
    private var composer: RecordingActivityComposer?
    private var meetingID: String?
    private var pending: Task<Void, Never>?

    public init() {}

    public var isActive: Bool { activityID != nil }

    /// Starts the activity for a recording. A second start for the same
    /// meeting is ignored; a different meeting replaces the old activity.
    public func begin(meetingID: String, title: String, startedAt: Date = Date()) {
        guard self.meetingID != meetingID else { return }
        end()
        self.meetingID = meetingID
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.info("Live Activities are turned off; recording continues without one")
            return
        }
        // Never more than one: dismiss anything left by an earlier process.
        endExisting()
        var composer = RecordingActivityComposer(startedAt: startedAt)
        let initial = composer.next(phase: .recording, title: title, duration: 0, caption: nil, now: startedAt)
            ?? composer.state(phase: .recording, title: title, duration: 0, caption: nil, now: startedAt)
        do {
            let activity = try Activity.request(attributes: RecordingActivityAttributes(meetingID: meetingID),
                                                content: ActivityContent(state: initial, staleDate: nil), pushType: nil)
            activityID = activity.id
            self.composer = composer
        } catch {
            Self.log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Feed every meter tick; updates are throttled internally.
    public func update(title: String, duration: Double, level: Float?, caption: String?, now: Date = Date()) {
        guard let activityID, var composer else { return }
        composer.record(level: level, duration: duration)
        let next = composer.next(phase: .recording, title: title, duration: duration, caption: caption, now: now)
        self.composer = composer
        guard let next else { return }
        // Keep at most one in-flight update; a newer state supersedes it.
        pending?.cancel()
        pending = Task { await Self.update(id: activityID, state: next) }
    }

    /// Shows the saving state briefly, then dismisses the activity.
    public func finish(title: String, duration: Double) {
        guard let activityID, let composer else { end(); return }
        let final = composer.state(phase: .saving, title: title, duration: duration, caption: nil, now: Date())
        self.activityID = nil; self.composer = nil; self.meetingID = nil
        pending?.cancel(); pending = nil
        Task { await Self.end(id: activityID, final: final, dismissAfter: Date().addingTimeInterval(4)) }
    }

    /// Ends immediately (failure, cancellation, app termination).
    public func end() {
        pending?.cancel(); pending = nil
        let current = activityID
        activityID = nil; composer = nil; meetingID = nil
        if let current { Task { await Self.end(id: current, final: nil, dismissAfter: nil) } }
    }

    /// Ends activities that exist right now except the current one, e.g. ones
    /// left by an earlier process. The list is captured synchronously so a
    /// recording started a moment later is never caught by this cleanup.
    public func endExisting() {
        let stale = Activity<RecordingActivityAttributes>.activities.map(\.id).filter { $0 != activityID }
        for id in stale { Task { await Self.end(id: id, final: nil, dismissAfter: nil) } }
    }

    /// Dismisses every recording activity, including ones from earlier processes.
    nonisolated public static func endAll() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func update(id: String, state: State) async {
        guard !Task.isCancelled,
              let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    nonisolated private static func end(id: String, final: State?, dismissAfter: Date?) async {
        guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(final.map { ActivityContent(state: $0, staleDate: nil) },
                           dismissalPolicy: dismissAfter.map { .after($0) } ?? .immediate)
    }
}
#endif
