import Foundation
import MinutesCore
import MinutesCalendar

@MainActor enum GoogleCalendarCLI {
    static func run(arguments: [String]) async throws {
        guard arguments.count >= 3, ["auth", "status", "events", "calendars", "disconnect"].contains(arguments[2]),
              let flag = arguments.firstIndex(of: "--config"), flag + 1 < arguments.count else {
            throw GoogleCLIError.usage
        }
        let config = try GoogleCalendarConfiguration.decodePublicMetadata(Data(contentsOf: URL(fileURLWithPath: arguments[flag + 1])))
        let connection = GoogleCalendarConnection(configuration: config)
        switch arguments[2] {
        case "auth":
            print("Opening Google authorization in your system browser. Only read-only Calendar access is requested.")
            try await connection.connect(using: GoogleSystemBrowserAgent())
            print("Google Calendar connected. Credentials are stored in Keychain.")
        case "status":
            let status = try await connection.status()
            print(status.connected ? "Google Calendar connected (saved authorization; network access not checked)." : "Google Calendar disconnected.")
        case "disconnect":
            try await connection.disconnect(revoke: !arguments.contains("--local-only"))
            print("Local Google authorization removed.")
        case "calendars":
            for item in try await connection.calendars() { print("\(item.id)  \(item.summary ?? "")") }
        default:
            var days = 7
            if let index = arguments.firstIndex(of: "--days"), index + 1 < arguments.count {
                guard let number = Int(arguments[index + 1]), (1...31).contains(number) else { throw CalendarAccessError.invalidInterval }
                days = number
            }
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
            let events = try await connection.events(in: DateInterval(start: start, end: end))
            if arguments.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(events), as: UTF8.self))
            } else {
                for event in events { print("\(event.start.formatted())  \(event.title)  [\(event.id)]") }
                if events.isEmpty { print("No timed meetings in the configured calendars and interval.") }
            }
        }
    }
    enum GoogleCLIError: Error, LocalizedError {
        case usage
        var errorDescription: String? { "Usage: minutes-cli google auth|status|events|calendars|disconnect --config <public-client-metadata.json> [--days 7] [--json] [--local-only]" }
    }
}
