import Foundation

/// Bridge from Live Activity App Intents (which run in the app process) to the
/// same recording actions the in-app buttons use. The app registers handlers at
/// launch; until then (or in the widget extension) the commands do nothing.
@MainActor public final class RecordingActivityCommands {
    public static let shared = RecordingActivityCommands()
    public var stopRecording: (@MainActor () async -> Void)?
    public var markMoment: (@MainActor () -> Void)?
    /// Called when an intent arrives without a live recording handler, so a
    /// stale activity (for example after a crash) can be dismissed.
    public var endStaleActivities: (@MainActor () async -> Void)?
    public init() {}

    public func stop() async {
        if let stopRecording { await stopRecording() } else { await endStaleActivities?() }
    }

    public func mark() async {
        if let markMoment { markMoment() } else { await endStaleActivities?() }
    }
}
