import Foundation
import Testing
import MinutesCore
import MinutesExport

struct SummaryTranscriptExportTests {
    @Test func compactSummaryExportStillIncludesTheCompleteTranscriptSeparately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-summary-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(id: "summary-export", title: "Synthetic export", platform: "transcript_import")
        let summary = MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "A short draft", markdown: "# Synthetic export\n\n## Generated notes (review required)\n- Short draft [T0001]")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: "", speakerName: "Unknown", start: 0, end: 0, text: "Complete original source text remains separate.")
        let result = try await MarkdownAdapter(outputDirectory: root.path).export(bundle: .init(meeting: meeting, attendees: [], clusters: [], utterances: [utterance], summary: summary))
        let output = try String(contentsOfFile: #require(result.pathOrURL), encoding: .utf8)
        #expect(output.contains("- Short draft\n") || output.hasSuffix("- Short draft") || output.contains("- Short draft\n\n"))
        #expect(!output.contains("[T0001]"))
        #expect(output.contains("## Transcript\n"))
        #expect(output.contains("**Unknown** (untimed): " + utterance.text))
        #expect(output.components(separatedBy: utterance.text).count == 2)
    }
}
