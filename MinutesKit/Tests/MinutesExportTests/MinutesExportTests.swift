import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesExport

@Suite("MinutesExport Tests")
struct MinutesExportTests {
    @Test("MarkdownAdapter exports Obsidian-compatible front matter and summary")
    func testMarkdownAdapter() async throws {
        let tempDir = NSTemporaryDirectory()
        let outDir = (tempDir as NSString).appendingPathComponent("minutes_test_\(UUID().uuidString)")
        
        let meeting = Meeting(title: "Sprint Planning", status: "finalized")
        let person = Person(displayName: "Ana Lopez", emails: ["ana@example.com"])
        let cluster = SpeakerCluster(meetingId: meeting.id, trackId: "t1", label: "Ana Lopez")
        let utterance = Utterance(id: 1, meetingId: meeting.id, clusterId: cluster.id, speakerName: "Ana Lopez", start: 0.0, end: 4.0, text: "Let's review the sprint backlog.")
        let summary = MeetingSummary(
            meetingId: meeting.id,
            title: meeting.title,
            overview: "Overview of sprint goals.",
            decisions: ["Adopt Parakeet Ultra ASR"],
            actionItems: [ActionItem(text: "Write unit tests", owner: "Ana")],
            markdown: "## Overview\nOverview of sprint goals.\n\n## Key Decisions\n- Adopt Parakeet Ultra ASR\n"
        )
        
        let bundle = MeetingExportBundle(
            meeting: meeting,
            attendees: [person],
            clusters: [cluster],
            utterances: [utterance],
            summary: summary
        )
        
        let adapter = MarkdownAdapter(outputDirectory: outDir)
        let result = try await adapter.export(bundle: bundle)
        
        #expect(result.success == true)
        #expect(result.pathOrURL != nil)
        
        let content = try String(contentsOfFile: result.pathOrURL!, encoding: .utf8)
        #expect(content.contains("---"))
        #expect(content.contains("title: \"Sprint Planning\""))
        #expect(content.contains("tags: [meeting]"))
        #expect(content.contains("Adopt Parakeet Ultra ASR"))
    }
}
