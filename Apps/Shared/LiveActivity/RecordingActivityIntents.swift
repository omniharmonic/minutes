import AppIntents
import MinutesActivity

// Compiled into both the app and the widget extension so the Live Activity
// buttons can reference them. LiveActivityIntent runs `perform` in the app
// process, where the app registered RecordingActivityCommands handlers.

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the current Minutes recording and saves it for processing.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingActivityCommands.shared.stop()
        return .result()
    }
}

struct MarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Moment"
    static let description = IntentDescription("Marks the current moment of the Minutes recording.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingActivityCommands.shared.mark()
        return .result()
    }
}
