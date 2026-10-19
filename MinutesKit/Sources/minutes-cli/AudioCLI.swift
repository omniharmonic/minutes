import Foundation
import MinutesCore
import MinutesSpeech

/// `minutes-cli audio usage | compact <id|--all> | delete <id> [--data-dir <path>]`
enum AudioCLI {
    static func run(arguments: [String], store: MinutesStore, managedDirectory: URL) async throws {
        var rest = Array(arguments.dropFirst(2))
        if let flag = rest.firstIndex(of: "--data-dir") { rest.removeSubrange(flag..<min(flag + 2, rest.endIndex)) }
        let format = ByteCountFormatter()
        switch rest.first {
        case "usage":
            let meetings = store.listMeetings() + store.listMeetings(inTrash: true)
            let rows = meetings.map { ($0, AudioStorage.usage(audioPath: $0.audioPath)) }.filter { $0.1.exists }.sorted { $0.1.bytes > $1.1.bytes }
            for (meeting, usage) in rows {
                print("\(format.string(fromByteCount: usage.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(usage.isCompact ? "compact " : "original") \(meeting.id)  \(meeting.title)")
            }
            print("Total: \(format.string(fromByteCount: rows.reduce(0) { $0 + $1.1.bytes })) across \(rows.count) recordings")
        case "compact":
            let ids: [String]
            if rest.dropFirst().first == "--all" {
                ids = (store.listMeetings() + store.listMeetings(inTrash: true)).filter { AudioStorage.isCompactable($0) && !AudioStorage.usage(audioPath: $0.audioPath).isCompact }.map(\.id)
            } else if let id = rest.dropFirst().first { ids = [id] } else { throw usageError }
            var freed: Int64 = 0
            for id in ids {
                do { freed += try await AudioStorage.compactMeeting(id: id, store: store, managedDirectory: managedDirectory) }
                catch { print("Kept \(id): \(error.localizedDescription)") }
            }
            print("Compacted \(ids.count) recording(s); freed \(format.string(fromByteCount: freed)).")
        case "delete":
            guard let id = rest.dropFirst().first else { throw usageError }
            let freed = try AudioStorage.deleteMeetingAudio(id: id, store: store, managedDirectory: managedDirectory)
            print("Deleted audio for \(id) (\(format.string(fromByteCount: freed))). Transcript, speakers and notes are kept.")
        default: throw usageError
        }
    }

    static let usageError = NSError(domain: "MinutesCLI", code: 64, userInfo: [NSLocalizedDescriptionKey:
        "Usage: minutes-cli audio usage | compact <meeting-id|--all> | delete <meeting-id> [--data-dir <path>]"])
}
