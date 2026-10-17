import Foundation
import MinutesCore

/// Shared by CLI and app. A successful audio import always owns a durable,
/// validated copy; importing text never invents timing or speaker embeddings.
public final class AudioImportService: Sendable {
    private let store: MinutesStore
    private let audioDirectory: URL
    public init(store: MinutesStore, audioDirectory: URL) {
        self.store = store
        self.audioDirectory = audioDirectory
    }

    public func importAudio(from source: URL, title: String? = nil) throws -> Meeting {
        guard source.isFileURL else { throw ASRError.audioUnreadable("Choose a local audio file") }
        try validateAudio(source)
        let id = UUID().uuidString.lowercased()
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension
        let managedURL = audioDirectory.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: managedURL)
            // Verify the actual copied file, rather than trusting a mutable source.
            try validateAudio(managedURL)
            let meeting = Meeting(id: id, title: resolvedTitle(title, source: source), status: "recorded", audioPath: managedURL.path)
            try store.saveMeeting(meeting)
            return meeting
        } catch {
            try? FileManager.default.removeItem(at: managedURL)
            throw error
        }
    }

    public func importTranscript(from source: URL, title: String? = nil) throws -> Meeting {
        guard source.isFileURL else { throw ASRError.audioUnreadable("Choose a local transcript file") }
        let text = try String(contentsOf: source, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ASRError.audioUnreadable("Transcript is empty") }
        let meeting = Meeting(id: UUID().uuidString.lowercased(), title: resolvedTitle(title, source: source), platform: "transcript_import", status: "needs_review")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: "untimed", speakerName: "Unknown speaker", start: 0, end: 0, text: text)
        try store.withTransaction {
            try store.saveMeeting(meeting)
            try store.saveUtterances([utterance])
        }
        return meeting
    }

    private func validateAudio(_ url: URL) throws {
        let decoded = try AudioDecoder.decode(fileURL: url)
        guard decoded.duration > 0, !decoded.samples.isEmpty else {
            throw ASRError.audioUnreadable("The file contains no audio frames")
        }
    }

    private func resolvedTitle(_ title: String?, source: URL) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : source.lastPathComponent
    }
}
