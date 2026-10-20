import Foundation
import MinutesCore
import MinutesExport

/// `minutes-cli vault …`: sign in to a Parachute hub and save meetings to the chosen vault.
@MainActor enum ParachuteVaultCLI {
    static func run(arguments: [String], store: MinutesStore) async throws {
        guard arguments.count > 2, let index = arguments.firstIndex(of: "--server"), index + 1 < arguments.count else {
            print("Usage: minutes-cli vault signin|status|verify|signout --server <host>\n       minutes-cli vault export <meeting-id> --server <host> [--folder Meetings]")
            exit(1)
        }
        let connection = try ParachuteVaultConnection(origin: ParachuteVaultConnection.normalizedOrigin(arguments[index + 1]))
        switch arguments[2] {
        case "signin":
            print("Opening your browser. Sign in and choose the vault Minutes may write to…")
            let browser = OAuthSystemBrowserSession()
            let status = try await connection.connect { url, receiver, state in
                try await browser.authorize(url: url, loopback: receiver, expectedState: state)
            }
            print("Signed in. Saving to vault “\(status.vault)” at \(status.vaultURL.absoluteString).")
        case "status":
            if let status = try await connection.status(allowInteraction: true) { print("Signed in to vault “\(status.vault)” at \(status.vaultURL.absoluteString).") }
            else { print("Not signed in. Run: minutes-cli vault signin --server \(connection.origin.host ?? "")") }
        case "verify":
            let status = try await connection.verify()
            print("Vault “\(status.vault)” answered.")
        case "signout":
            await connection.disconnect()
            print("Signed out. Notes already in the vault are unchanged.")
        case "export":
            guard arguments.count > 3, let meeting = store.getMeeting(id: arguments[3]) else { print("Meeting not found."); exit(1) }
            guard let status = try await connection.status(allowInteraction: true) else { throw ParachuteVaultError.notConnected }
            var folder = "Meetings"
            if let flag = arguments.firstIndex(of: "--folder"), flag + 1 < arguments.count { folder = arguments[flag + 1] }
            let clusters = store.listSpeakerClusters(meetingId: meeting.id)
            let bundle = MeetingExportBundle(meeting: meeting, attendees: store.listPeopleForMeeting(meetingId: meeting.id), clusters: clusters,
                utterances: TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meeting.id), clusters: clusters),
                summary: store.getSummary(meetingId: meeting.id))
            let key = ParachuteMeetingNote.receiptKey(vaultURL: status.vaultURL, meetingID: meeting.id)
            let previous = try store.librarySetting(key).flatMap { try? JSONDecoder().decode(ParachuteNoteReceipt.self, from: Data($0.utf8)) }
            let receipt = try await ParachuteMeetingNote.save(bundle, folder: folder, previous: previous, using: connection)
            try store.setLibrarySetting(key, value: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
            print("Saved to \(status.vault): \(ParachuteMeetingNote.path(folder: folder, meeting: meeting)) (note \(receipt.id))")
        default:
            print("Unknown vault command: \(arguments[2])"); exit(1)
        }
    }
}

/// `minutes-cli bookmarks …`: the moments marked in a meeting.
enum BookmarkCLI {
    static func run(arguments: [String], store: MinutesStore) throws {
        guard arguments.count > 3 else {
            print("Usage: minutes-cli bookmarks list <meeting-id>\n       minutes-cli bookmarks add <meeting-id> <seconds> [label]\n       minutes-cli bookmarks rename <meeting-id> <bookmark-id> <label>\n       minutes-cli bookmarks delete <meeting-id> <bookmark-id>")
            exit(1)
        }
        let meetingID = arguments[3]
        guard store.getMeeting(id: meetingID) != nil else { print("Meeting not found."); exit(1) }
        switch arguments[2] {
        case "list":
            let marks = store.listBookmarks(meetingId: meetingID)
            if marks.isEmpty { print("No moments marked.") }
            for mark in marks { print("\(mark.id)  \(SummaryCitations.timecode(mark.timestamp))  \(mark.label)") }
        case "add":
            guard arguments.count > 4, let seconds = Double(arguments[4]), seconds >= 0 else { print("Give the time in seconds."); exit(1) }
            let mark = Bookmark(meetingId: meetingID, timestamp: seconds, label: arguments.count > 5 ? arguments[5...].joined(separator: " ") : "Key moment")
            try store.saveBookmark(mark)
            print("Marked \(SummaryCitations.timecode(seconds)) [\(mark.id)]")
        case "rename":
            guard arguments.count > 5, var mark = store.listBookmarks(meetingId: meetingID).first(where: { $0.id == arguments[4] }) else { print("Moment not found."); exit(1) }
            mark.label = arguments[5...].joined(separator: " ")
            try store.saveBookmark(mark)
            print("Renamed.")
        case "delete":
            guard arguments.count > 4 else { print("Give the moment id."); exit(1) }
            try store.deleteBookmark(id: arguments[4])
            print("Removed.")
        default:
            print("Unknown bookmarks command: \(arguments[2])"); exit(1)
        }
    }
}
