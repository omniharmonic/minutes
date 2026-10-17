import Foundation
import CryptoKit
import MinutesCore

public final class OutboxManager: Sendable {
    public let store: MinutesStore
    public let client: PrismClientProtocol
    public let maxRetries: Int
    public let baseBackoff: TimeInterval
    public let destinationOrigin: String?
    public let grantFingerprint: String?
    
    public init(
        store: MinutesStore,
        client: PrismClientProtocol,
        maxRetries: Int = 5,
        baseBackoff: TimeInterval = 1.0,
        destinationOrigin: String? = nil,
        grantFingerprint: String? = nil
    ) {
        self.store = store
        self.client = client
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
        self.destinationOrigin = destinationOrigin
        self.grantFingerprint = grantFingerprint
    }
    
    // MARK: - Enqueue Meeting
    
    public func enqueue(bundle: MeetingExportBundle, destinationVault: String, sourceRevision: Int = 1, baseServerRevision: Int? = nil) throws -> OutboxItem {
        try store.enqueueOutboxItem(makeItem(bundle: bundle, destinationVault: destinationVault, sourceRevision: sourceRevision, baseServerRevision: baseServerRevision))
    }

    /// An unchanged delivery reuses its identity. Changed content cannot overtake a pending import.
    public func enqueueNextRevision(bundle: MeetingExportBundle, destinationVault: String, resolvingConflictAt serverRevision: Int? = nil) throws -> OutboxItem {
        var result: OutboxItem?
        try store.withImmediateTransaction {
            let previous = store.listOutboxItems(meetingId: bundle.meeting.id).filter {
                $0.destinationVault == destinationVault && $0.destinationOrigin == destinationOrigin && $0.grantFingerprint == grantFingerprint
            }.max { $0.sourceRevision < $1.sourceRevision }
            if let previous {
                let comparison = try makeItem(bundle: bundle, destinationVault: destinationVault, sourceRevision: previous.sourceRevision, baseServerRevision: previous.baseServerRevision)
                if comparison.payloadJson == previous.payloadJson && !(previous.status == .conflict && serverRevision != nil) { result = previous; return }
                let base: Int
                if previous.status == .synced, let committed = previous.receipt?.serverRevision, committed > 0 { base = committed }
                else if previous.status == .conflict, let supplied = serverRevision, supplied > 0 { base = supplied }
                else { throw PrismError.conflict(serverRevision: previous.receipt?.serverRevision, message: "Resolve or finish the existing delivery before queueing edited content") }
                guard previous.sourceRevision < Int(Int32.max) else { throw PrismError.invalidPayload("Revision limit reached") }
                result = try store.enqueueOutboxItem(makeItem(bundle: bundle, destinationVault: destinationVault, sourceRevision: previous.sourceRevision + 1, baseServerRevision: base))
            } else {
                result = try store.enqueueOutboxItem(makeItem(bundle: bundle, destinationVault: destinationVault, sourceRevision: 1, baseServerRevision: nil))
            }
        }
        guard let result else { throw PrismError.invalidPayload("Queue operation returned no result") }
        return result
    }

    private func makeItem(bundle: MeetingExportBundle, destinationVault: String, sourceRevision: Int, baseServerRevision: Int?) throws -> OutboxItem {
        let isoFmt = ISO8601DateFormatter()
        let startedAtStr = isoFmt.string(from: bundle.meeting.startedAt)
        let endedAtStr: String?
        if let ended = bundle.meeting.endedAt {
            endedAtStr = isoFmt.string(from: ended)
        } else {
            endedAtStr = nil
        }
        
        let peopleCtx = bundle.attendees.map { p in
            PrismPersonContext(
                sourcePersonId: p.id,
                displayName: p.displayName,
                emails: p.emails,
                attendance: bundle.clusters.contains { $0.personId == p.id && $0.assignment == "user" } ? "confirmed" : "invited"
            )
        }
        
        let peopleIds = Set(peopleCtx.map(\.sourcePersonId))
        let utterancesCtx = bundle.utterances.map { u in
            let cluster = bundle.clusters.first { $0.id == u.clusterId && $0.meetingId == u.meetingId }
            let personId = cluster?.personId.flatMap { peopleIds.contains($0) ? $0 : nil }
            let assignment = personId == nil ? "unassigned" : (cluster?.assignment == "user" ? "user" : "model")
            return PrismUtteranceContext(
                id: "\(u.id)", startMs: Int(u.start * 1000.0), endMs: Int(u.end * 1000.0),
                text: u.text, speakerPersonId: personId, assignment: assignment
            )
        }

        let notesText = bundle.meeting.userNotes ?? ""
        let summaryText = bundle.summary?.markdown ?? ""
        let contentHash = PrismMeetingPayload.computeContentHash(
            title: bundle.meeting.title,
            startedAt: startedAtStr,
            people: peopleCtx,
            utterances: utterancesCtx,
            notesMarkdown: notesText,
            summaryMarkdown: summaryText
        )
        
        let summaryCtx = PrismSummaryContext(
            markdown: summaryText,
            status: bundle.summary != nil ? "completed" : "not_generated",
            // Typed citation references are not persisted in MeetingSummary yet.
            // Keep evidence empty rather than inventing references from decision text.
            evidence: []
        )
        
        let payload = PrismMeetingPayload(
            schemaVersion: 1,
            sourceMeetingId: bundle.meeting.id,
            sourceRevision: sourceRevision,
            title: bundle.meeting.title,
            startedAt: startedAtStr,
            endedAt: endedAtStr,
            timeZone: TimeZone.current.identifier,
            calendar: nil,
            people: peopleCtx,
            utterances: utterancesCtx,
            notesMarkdown: notesText,
            summary: summaryCtx,
            contentHash: contentHash
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        guard let payloadJson = String(data: payloadData, encoding: .utf8) else {
            throw PrismError.invalidPayload("Cannot serialize payload to UTF8 string")
        }
        
        // Scope delivery identity to both destination and the complete payload.
        let rawIdemKey = (grantFingerprint.map { Data($0.utf8) + Data([0]) } ?? Data()) + (destinationOrigin.map { Data($0.utf8) + Data([0]) } ?? Data()) + Data(destinationVault.utf8) + Data([0]) + payloadData
        let digest = SHA256.hash(data: rawIdemKey)
        let idempotencyKey = digest.compactMap { String(format: "%02x", $0) }.joined()
        
        let item = OutboxItem(
            id: UUID().uuidString.lowercased(),
            meetingId: bundle.meeting.id,
            destinationVault: destinationVault,
            destinationOrigin: destinationOrigin,
            grantFingerprint: grantFingerprint,
            baseServerRevision: baseServerRevision,
            sourceRevision: sourceRevision,
            idempotencyKey: idempotencyKey,
            status: .pending,
            retryCount: 0,
            createdAt: Date(),
            lastAttemptAt: nil,
            receipt: nil,
            errorMessage: nil,
            payloadJson: payloadJson
        )
        
        return item
    }
    
    // MARK: - Process Pending Outbox Items
    
    @discardableResult
    public func processPending() async throws -> [OutboxItem] {
        let now = Date()
        let candidates = store.listOutboxItems(meetingId: nil, status: nil).filter { item in
            guard item.destinationOrigin == destinationOrigin && item.grantFingerprint == grantFingerprint else { return false }
            switch item.status {
            case .pending: return true
            case .sending:
                return item.lastAttemptAt == nil || now.timeIntervalSince(item.lastAttemptAt!) > 120
            case .failedRetryable, .awaitingReceipt:
                guard item.retryCount < maxRetries else { return false }
                let backoff = min(60, baseBackoff * pow(2, Double(min(item.retryCount, 6))))
                return item.lastAttemptAt == nil || now.timeIntervalSince(item.lastAttemptAt!) >= backoff
            default: return false
            }
        }
        var processed: [OutboxItem] = []
        for item in candidates {
            if let result = try await sendClaimed(item) { processed.append(result) }
        }
        return processed
    }

    // The SQL claim, rather than an in-memory lock, coordinates separate workers.
    private func sendClaimed(_ original: OutboxItem) async throws -> OutboxItem? {
        let claimedAt = Date()
        guard try store.claimOutboxItem(id: original.id, at: claimedAt,
                staleBefore: claimedAt.addingTimeInterval(-120)) else { return nil }
        guard var item = store.getOutboxItem(id: original.id) else {
            throw PrismError.invalidPayload("Claimed outbox row disappeared")
        }
        guard item.status == .sending, item.lastAttemptAt?.timeIntervalSince1970 == claimedAt.timeIntervalSince1970 else { return item }
        do {
            let payload = try JSONDecoder().decode(PrismMeetingPayload.self, from: Data(item.payloadJson.utf8))
            let receipt = try await client.uploadMeeting(payload: payload,
                destinationVault: item.destinationVault, idempotencyKey: item.idempotencyKey,
                baseRevision: item.baseServerRevision)
            item.status = .synced
            item.receipt = receipt
            item.errorMessage = nil
        } catch let error as PrismError {
            item.errorMessage = error.localizedDescription
            switch error {
            case .acceptedPending:
                item.status = .awaitingReceipt
                item.retryCount += 1
            case .needsSignIn: item.status = .needsSignIn
            case .forbidden: item.status = .forbidden
            case .conflict, .invalidPayload, .unhandledResponse: item.status = .conflict
            case .failedRetryable:
                item.retryCount += 1
                item.status = .failedRetryable
            }
        } catch is DecodingError {
            item.status = .conflict
            item.errorMessage = "Failed to parse stored payload JSON"
        } catch {
            item.retryCount += 1
            item.status = .failedRetryable
            item.errorMessage = error.localizedDescription
        }
        item.lastAttemptAt = Date()
        if try store.finishOutboxClaim(item, claimedAt: claimedAt) { return item }
        // Cancellation or another worker's newer claim takes precedence.
        return store.getOutboxItem(id: item.id)
    }

    public func retryItem(id: String) async throws -> OutboxItem {
        guard let original = store.getOutboxItem(id: id) else {
            throw PrismError.invalidPayload("Outbox item not found: \(id)")
        }
        guard original.destinationOrigin == destinationOrigin && original.grantFingerprint == grantFingerprint else { throw PrismError.forbidden("This export belongs to a different Prism origin") }
        guard original.status != .revoked else {
            throw PrismError.invalidPayload("Cancelled exports must be enqueued explicitly")
        }
        if original.status == .synced { return original }
        try store.resetOutboxForRetry(id: id)
        guard let item = store.getOutboxItem(id: id), let result = try await sendClaimed(item) else {
            throw PrismError.invalidPayload("Outbox item is already being sent")
        }
        return result
    }

    public func cancelItem(id: String) throws {
        guard var item = store.getOutboxItem(id: id) else {
            throw PrismError.invalidPayload("Outbox item not found: \(id)")
        }
        item.status = .revoked
        item.errorMessage = "Cancelled by user; an already accepted remote upload may still complete"
        try store.saveOutboxItem(item)
    }
}
