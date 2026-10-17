import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

private actor CountingPrismClient: PrismClientProtocol {
    var count = 0
    let beforeReceipt: @Sendable () throws -> Void
    init(beforeReceipt: @escaping @Sendable () throws -> Void = {}) { self.beforeReceipt = beforeReceipt }
    func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
        count += 1
        try await Task.sleep(for: .milliseconds(50))
        try beforeReceipt()
        return PrismReceipt(importId: "import", meetingNoteId: "meeting", transcriptNoteId: "transcript", serverRevision: 1, contentHash: payload.contentHash)
    }
}

struct OutboxRecoveryTests {
    private func environment() throws -> (MinutesStore, URL, MeetingExportBundle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-recovery-\(UUID()).sqlite")
        let store = try MinutesStore(dbPath: url.path)
        let meeting = Meeting(id: "test-meeting", title: "Recovery")
        try store.saveMeeting(meeting)
        return (store, url, MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil))
    }

    @Test("Interrupted sending rows are recovered with the original idempotency key")
    func staleSendRecovers() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CountingPrismClient()
        let outbox = OutboxManager(store: store, client: client, baseBackoff: 0)
        var item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        item.status = .sending
        item.lastAttemptAt = Date(timeIntervalSinceNow: -3600)
        try store.saveOutboxItem(item)
        let processed = try await outbox.processPending()
        #expect(processed.first?.status == .synced)
        #expect(processed.first?.idempotencyKey == item.idempotencyKey)
    }

    @Test("Two independent workers cannot send the same pending row concurrently")
    func concurrentWorkersClaimOnce() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let secondConnection = try MinutesStore(dbPath: url.path)
        let client = CountingPrismClient()
        let first = OutboxManager(store: store, client: client)
        let second = OutboxManager(store: secondConnection, client: client)
        _ = try first.enqueue(bundle: bundle, destinationVault: "default")
        async let a = first.processPending()
        async let b = second.processPending()
        _ = try await (a, b)
        #expect(await client.count == 1)
    }

    @Test("Cancellation during upload cannot be overwritten by its late receipt")
    func cancellationWins() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CountingPrismClient {
            var item = store.listOutboxItems(meetingId: nil, status: nil)[0]
            item.status = .revoked
            try store.saveOutboxItem(item)
        }
        let outbox = OutboxManager(store: store, client: client)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        _ = try await outbox.processPending()
        #expect(store.getOutboxItem(id: item.id)?.status == .revoked)
    }

    @Test("Accepted pending rows can obtain a committed receipt on idempotent retry")
    func awaitingReceiptRecovers() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CountingPrismClient()
        let outbox = OutboxManager(store: store, client: client, baseBackoff: 0)
        var item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        item.status = .awaitingReceipt
        item.lastAttemptAt = Date(timeIntervalSinceNow: -3600)
        try store.saveOutboxItem(item)
        #expect(try await outbox.processPending().first?.status == .synced)
    }

    @Test("Automatic retry stops at its configured failure limit")
    func retryBudgetIsEnforced() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CountingPrismClient()
        let outbox = OutboxManager(store: store, client: client, maxRetries: 3, baseBackoff: 0)
        var item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        item.status = .failedRetryable
        item.retryCount = 3
        item.lastAttemptAt = Date(timeIntervalSinceNow: -3600)
        try store.saveOutboxItem(item)
        #expect(try await outbox.processPending().isEmpty)
        #expect(await client.count == 0)
    }
    @Test("Concurrent enqueue across independent connections inserts one durable delivery")
    func concurrentEnqueueIsAtomic() async throws {
        let (store, url, bundle) = try environment()
        defer { try? FileManager.default.removeItem(at: url) }
        let other = try MinutesStore(dbPath: url.path)
        let item = OutboxItem(id: "first", meetingId: bundle.meeting.id, destinationVault: "default", idempotencyKey: "same", payloadJson: "{}")
        let duplicate = OutboxItem(id: "second", meetingId: bundle.meeting.id, destinationVault: "default", idempotencyKey: "same", payloadJson: "{}")
        async let first = store.enqueueOutboxItem(item)
        async let second = other.enqueueOutboxItem(duplicate)
        let (a, b) = try await (first, second)
        #expect(a.id == b.id)
        #expect(store.listOutboxItems(meetingId: nil, status: nil).count == 1)
    }

}

struct OutboxOriginBindingTests {
    @Test func originIsDurableAndLegacyWorkerDoesNotSendScopedRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("origin.sqlite").path
        let store = try MinutesStore(dbPath: path)
        try store.saveMeeting(Meeting(id: "fixture", title: "Origin fixture"))
        let item = OutboxItem(meetingId: "fixture", destinationVault: "vault", destinationOrigin: "https://prism.example", idempotencyKey: "key", payloadJson: "{}")
        try store.saveOutboxItem(item)
        let reopened = try MinutesStore(dbPath: path)
        #expect(reopened.getOutboxItem(id: item.id)?.destinationOrigin == "https://prism.example")
        let client = OriginNeverSendClient()
        let legacy = OutboxManager(store: reopened, client: client)
        #expect(try await legacy.processPending().isEmpty)
        await #expect(throws: (any Error).self) { try await legacy.retryItem(id: item.id) }
        #expect(await client.called == false)
    }
}
private actor OriginNeverSendClient: PrismClientProtocol {
    var called = false
    func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
        called = true
        throw PrismError.forbidden("Unexpected send")
    }
}
