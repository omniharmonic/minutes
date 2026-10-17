import Foundation
import MinutesCore
import MinutesExport

@MainActor enum PrismConnectionCLI {
    static func run(arguments: [String], store: MinutesStore) async throws {
        guard arguments.count > 2, let index = arguments.firstIndex(of: "--origin"), index + 1 < arguments.count,
              let origin = URL(string: arguments[index + 1]) else { throw Usage.invalid }
        let connection = try PrismConnection(origin: origin, store: store)
        switch arguments[2] {
        case "status":
            let status = try await connection.status()
            print(status.hasCredential ? "Saved Prism authorization exists. Run verify before exporting." : "Prism disconnected. Use Connect Prism in the native app to authorize a restricted Minutes grant.")
        case "verify":
            let capabilities = try await connection.verifyCapabilities()
            for vault in capabilities.vaults { print("\(vault.id)  \(vault.name ?? "")") }
        case "outbox":
            for item in await connection.outboxItems(includeSynced: arguments.contains("--include-synced")) {
                print("\(item.id)  \(item.status.rawValue)  \(item.destinationVault)  meeting=\(item.meetingId)")
            }
        case "sync":
            for item in try await connection.syncPending() { print("\(item.id)  \(item.status.rawValue)") }
        case "disconnect":
            try await connection.disconnect(revoke: !arguments.contains("--local-only"))
            print("Local Prism authorization removed.")
        case "enqueue":
            guard arguments.count > 3, let flag = arguments.firstIndex(of: "--vault"), flag + 1 < arguments.count,
                  let meeting = store.getMeeting(id: arguments[3]) else { throw Usage.invalid }
            try await connection.verifyCapabilities()
            let directory: String?
            if let index = arguments.firstIndex(of: "--folder") {
                guard index + 1 < arguments.count else { throw Usage.invalid }
                directory = arguments[index + 1]
                try PrismExportDirectory.validate(directory!)
            } else { directory = nil }
            let bundle = MeetingExportBundle(meeting: meeting, attendees: store.listPeopleForMeeting(meetingId: meeting.id),
                clusters: store.listSpeakerClusters(meetingId: meeting.id), utterances: store.listUtterances(meetingId: meeting.id), summary: store.getSummary(meetingId: meeting.id), destinationDirectory: directory)
            let item = try await connection.enqueue(bundle: bundle, destinationVault: arguments[flag + 1])
            print("Queued \(item.id) for \(item.destinationOrigin ?? "") / \(item.destinationVault). Run prism sync explicitly to send.")
        default: throw Usage.invalid
        }
    }
    enum Usage: Error, LocalizedError {
        case invalid
        var errorDescription: String? { "Usage: minutes-cli prism status|verify|outbox|sync|disconnect --origin <https-origin>; prism enqueue <meeting-id> --origin <https-origin> --vault <granted-vault-id>. Authorize through Connect Prism in the native app first." }
    }
}
