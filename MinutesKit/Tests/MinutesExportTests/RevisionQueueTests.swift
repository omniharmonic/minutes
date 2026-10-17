import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

private actor RevisionFixtureClient: PrismClientProtocol {
    var bases: [Int?] = []
    func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
        bases.append(baseRevision)
        return PrismReceipt(importId: "import", meetingNoteId: "note", transcriptNoteId: "transcript", serverRevision: 47, contentHash: payload.contentHash)
    }
}
struct RevisionQueueTests {
    @Test func repeatedPendingAndCommittedEditsUseCorrectRevisions() async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        var meeting = Meeting(id: "fixture", title: "Original"); try store.saveMeeting(meeting)
        func bundle() -> MeetingExportBundle { .init(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil) }
        let client = RevisionFixtureClient()
        let manager = OutboxManager(store: store, client: client, destinationOrigin: "https://fixture.invalid", grantFingerprint: "grant-A")
        let first = try manager.enqueueNextRevision(bundle: bundle(), destinationVault: "vault")
        #expect(try manager.enqueueNextRevision(bundle: bundle(), destinationVault: "vault").id == first.id)
        meeting.title = "Edited"
        #expect(throws: (any Error).self) { try manager.enqueueNextRevision(bundle: bundle(), destinationVault: "vault") }
        _ = try await manager.processPending()
        let next = try manager.enqueueNextRevision(bundle: bundle(), destinationVault: "vault")
        #expect(next.sourceRevision == 2)
        #expect(next.baseServerRevision == 47)
        #expect(try manager.enqueueNextRevision(bundle: bundle(), destinationVault: "vault").id == next.id)
        _ = try await manager.processPending()
        #expect(await client.bases == [nil, 47])
        let changedGrant = OutboxManager(store: store, client: client, destinationOrigin: "https://fixture.invalid", grantFingerprint: "grant-B")
        #expect(try await changedGrant.processPending().isEmpty)
        await #expect(throws: (any Error).self) { try await changedGrant.retryItem(id: first.id) }
        let explicitlyRequeued = try changedGrant.enqueueNextRevision(bundle: bundle(), destinationVault: "vault")
        #expect(explicitlyRequeued.sourceRevision == 1)
        #expect(explicitlyRequeued.idempotencyKey != next.idempotencyKey)
        #expect(explicitlyRequeued.grantFingerprint == "grant-B")
    }
    @Test func vaultAndOriginAreIndependentRevisionStreams() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let meeting = Meeting(id: "fixture", title: "Original"); try store.saveMeeting(meeting)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil)
        let a = OutboxManager(store: store, client: RevisionFixtureClient(), destinationOrigin: "https://a.invalid", grantFingerprint: "grant")
        let b = OutboxManager(store: store, client: RevisionFixtureClient(), destinationOrigin: "https://b.invalid", grantFingerprint: "grant")
        let one = try a.enqueueNextRevision(bundle: bundle, destinationVault: "one")
        let two = try a.enqueueNextRevision(bundle: bundle, destinationVault: "two")
        let other = try b.enqueueNextRevision(bundle: bundle, destinationVault: "one")
        #expect([one, two, other].allSatisfy { $0.sourceRevision == 1 })
        #expect(Set([one.idempotencyKey, two.idempotencyKey, other.idempotencyKey]).count == 3)
    }
}
extension RevisionQueueTests {
    @Test func conflictRequiresExplicitServerPreconditionEvenForUnchangedContent() throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let meeting = Meeting(id: "fixture", title: "Original"); try store.saveMeeting(meeting)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil)
        let manager = OutboxManager(store: store, client: RevisionFixtureClient(), destinationOrigin: "https://fixture.invalid", grantFingerprint: "grant")
        var conflicted = try manager.enqueueNextRevision(bundle: bundle, destinationVault: "vault")
        conflicted.status = .conflict; try store.saveOutboxItem(conflicted)
        #expect(try manager.enqueueNextRevision(bundle: bundle, destinationVault: "vault").id == conflicted.id)
        let resolved = try manager.enqueueNextRevision(bundle: bundle, destinationVault: "vault", resolvingConflictAt: 93)
        #expect(resolved.sourceRevision == 2)
        #expect(resolved.baseServerRevision == 93)
    }
}
