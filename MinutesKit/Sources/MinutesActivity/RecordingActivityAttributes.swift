import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// Shared by the app and the widget extension. Deliberately dependency-free:
/// the extension must never link speech, diarization or storage stacks.
public struct RecordingActivityAttributes: Codable, Hashable, Sendable {
    /// Identifies the recording; never shown and never a transcript.
    public var meetingID: String

    public init(meetingID: String) { self.meetingID = meetingID }

    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Hashable, Sendable {
            /// Audio is being written; the timer ticks from `startedAt`.
            case recording
            /// Stop was requested; the recording is being finalized and saved.
            case saving
        }
        public var phase: Phase
        public var title: String
        /// Wall-clock anchor so `Text(timerInterval:)` ticks without updates.
        public var startedAt: Date
        /// Frozen elapsed seconds once the phase leaves `.recording`.
        public var frozenElapsed: Double?
        /// Recent input levels, oldest first, each 0...`RecordingWaveform.maximumLevel`.
        public var levels: [UInt8]
        /// Latest short live-caption line, only when captions are on.
        public var caption: String?

        public init(phase: Phase, title: String, startedAt: Date, frozenElapsed: Double? = nil,
                    levels: [UInt8], caption: String? = nil) {
            self.phase = phase; self.title = title; self.startedAt = startedAt
            self.frozenElapsed = frozenElapsed; self.levels = levels; self.caption = caption
        }

        /// Normalized 0...1 bar heights for drawing.
        public var normalizedLevels: [Double] { RecordingWaveform.normalized(levels) }
    }
}

#if os(iOS) && canImport(ActivityKit)
extension RecordingActivityAttributes: ActivityAttributes {}
#endif
