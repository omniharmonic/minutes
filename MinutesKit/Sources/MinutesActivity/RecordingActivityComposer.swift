import Foundation

/// Caption text shown on the Lock Screen / Dynamic Island.
public enum RecordingActivityCaption {
    public static let defaultLimit = 120

    /// Collapses whitespace and keeps the newest words (live text grows at the
    /// end), cutting at a word boundary with a leading ellipsis. Empty → nil.
    public static func truncate(_ text: String?, limit: Int = defaultLimit) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let limit = max(2, limit)
        guard collapsed.count > limit else { return collapsed }
        var tail = String(collapsed.suffix(limit - 1))
        if let space = tail.firstIndex(of: " "), tail.distance(from: tail.startIndex, to: space) < tail.count / 2 {
            tail = String(tail[tail.index(after: space)...])
        }
        return "…" + tail
    }
}

/// Decides when a Live Activity update is worth sending.
public struct RecordingActivityThrottle: Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var lastSent: RecordingActivityAttributes.ContentState?
    public private(set) var lastSentAt: Date?

    public init(minimumInterval: TimeInterval = 1) {
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 1
    }

    /// Unchanged state is never sent. Phase or title changes go immediately;
    /// everything else (levels, caption) waits for the minimum interval.
    public func shouldSend(_ state: RecordingActivityAttributes.ContentState, now: Date) -> Bool {
        guard let lastSent, let lastSentAt else { return true }
        guard state != lastSent else { return false }
        if state.phase != lastSent.phase || state.title != lastSent.title { return true }
        return now.timeIntervalSince(lastSentAt) >= minimumInterval
    }

    public mutating func markSent(_ state: RecordingActivityAttributes.ContentState, at now: Date) {
        lastSent = state; lastSentAt = now
    }
}

/// Pure state builder for the recording Live Activity: owns the waveform,
/// timer anchor and throttle, and answers "what (if anything) to send now".
public struct RecordingActivityComposer: Sendable {
    public private(set) var waveform: RecordingWaveform
    public private(set) var throttle: RecordingActivityThrottle
    public private(set) var startedAt: Date
    /// Re-anchor the timer only when it would visibly drift.
    public let anchorTolerance: TimeInterval

    public init(startedAt: Date, waveform: RecordingWaveform = RecordingWaveform(),
                throttle: RecordingActivityThrottle = RecordingActivityThrottle(), anchorTolerance: TimeInterval = 2) {
        self.startedAt = startedAt; self.waveform = waveform; self.throttle = throttle
        self.anchorTolerance = anchorTolerance
    }

    public mutating func record(level: Float?, duration: Double) {
        waveform.append(level: level ?? 0, at: duration)
    }

    public func state(phase: RecordingActivityAttributes.ContentState.Phase, title: String, duration: Double,
                      caption: String?, now: Date) -> RecordingActivityAttributes.ContentState {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(phase: phase, title: title.isEmpty ? "Recording" : String(title.prefix(80)),
                     startedAt: anchor(duration: duration, now: now),
                     frozenElapsed: phase == .recording ? nil : max(0, duration.isFinite ? duration : 0),
                     levels: phase == .recording ? waveform.levels : Array(repeating: 0, count: waveform.barCount),
                     caption: RecordingActivityCaption.truncate(caption))
    }

    /// Returns the state to send, or nil when throttled or unchanged.
    public mutating func next(phase: RecordingActivityAttributes.ContentState.Phase, title: String, duration: Double,
                              caption: String?, now: Date) -> RecordingActivityAttributes.ContentState? {
        let candidate = state(phase: phase, title: title, duration: duration, caption: caption, now: now)
        guard throttle.shouldSend(candidate, now: now) else { return nil }
        startedAt = candidate.startedAt
        throttle.markSent(candidate, at: now)
        return candidate
    }

    private func anchor(duration: Double, now: Date) -> Date {
        guard duration.isFinite, duration >= 0 else { return startedAt }
        let expected = now.addingTimeInterval(-duration)
        return abs(expected.timeIntervalSince(startedAt)) > anchorTolerance ? expected : startedAt
    }
}
