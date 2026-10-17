import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

private actor ProvenanceFixtureClient: PrismClientProtocol {
    func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
        throw PrismError.invalidPayload("This fixture must only enqueue local payloads")
    }
}

struct OutboxPayloadProvenanceTests {
    @Test func summaryDecisionsAreNotClaimedAsEvidenceReferences() throws {
        let payload = try enqueue(userNotes: "My original notes")
        #expect(payload.summary.evidence.isEmpty)
        #expect(payload.summary.markdown == "# Summary\n\nDecision: Ship on Friday.")
        #expect(payload.summary.status == "completed")
    }

    @Test(arguments: [nil, "", "My original notes"] as [String?])
    func userNotesRemainDistinctFromGeneratedSummary(userNotes: String?) throws {
        let payload = try enqueue(userNotes: userNotes)
        #expect(payload.notesMarkdown == (userNotes ?? ""))
        #expect(payload.summary.markdown == "# Summary\n\nDecision: Ship on Friday.")
        #expect(payload.notesMarkdown != payload.summary.markdown)
    }

    private func enqueue(userNotes: String?) throws -> PrismMeetingPayload {
        let store = try MinutesStore(dbPath: ":memory:")
        let meeting = Meeting(id: "provenance-fixture", title: "Planning", userNotes: userNotes)
        try store.saveMeeting(meeting)
        let summary = MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "Planning outcome",
            decisions: ["Ship on Friday."], markdown: "# Summary\n\nDecision: Ship on Friday.")
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: summary)
        let manager = OutboxManager(store: store, client: ProvenanceFixtureClient())
        let item = try manager.enqueue(bundle: bundle, destinationVault: "fixture-vault")
        return try JSONDecoder().decode(PrismMeetingPayload.self, from: Data(item.payloadJson.utf8))
    }
}
