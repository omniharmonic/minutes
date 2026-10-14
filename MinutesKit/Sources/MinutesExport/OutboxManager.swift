import Foundation
import CryptoKit
import MinutesCore

public final class OutboxManager: Sendable {
    public let store: MinutesStore
    public let client: PrismClientProtocol
    public let maxRetries: Int
    public let baseBackoff: TimeInterval
    
    public init(
        store: MinutesStore,
        client: PrismClientProtocol,
        maxRetries: Int = 5,
        baseBackoff: TimeInterval = 1.0
    ) {
        self.store = store
        self.client = client
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
    }
    
    // MARK: - Enqueue Meeting
    
    public func enqueue(
        bundle: MeetingExportBundle,
        destinationVault: String,
        sourceRevision: Int = 1
    ) throws -> OutboxItem {
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
                attendance: "confirmed"
            )
        }
        
        let utterancesCtx = bundle.utterances.map { u in
            PrismUtteranceContext(
                id: "\(u.id)",
                startMs: Int(u.start * 1000.0),
                endMs: Int(u.end * 1000.0),
                text: u.text,
                speakerPersonId: u.speakerName.isEmpty ? nil : u.speakerName,
                assignment: "user"
            )
        }
        
        let notesText = (bundle.meeting.userNotes?.isEmpty == false) ? (bundle.meeting.userNotes ?? "") : (bundle.summary?.markdown ?? "")
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
            evidence: bundle.summary?.decisions ?? []
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
        
        // Deterministic idempotency key: hash(meetingId:revision:contentHash)
        let rawIdemKey = "\(bundle.meeting.id):\(sourceRevision):\(contentHash)"
        let digest = SHA256.hash(data: Data(rawIdemKey.utf8))
        let idempotencyKey = digest.compactMap { String(format: "%02x", $0) }.joined()
        
        // Deduplication check
        let existingItems = store.listOutboxItems(meetingId: bundle.meeting.id, status: nil)
        if let existing = existingItems.first(where: { $0.idempotencyKey == idempotencyKey }) {
            // Already queued or synced with identical contents
            return existing
        }
        
        let item = OutboxItem(
            id: UUID().uuidString.prefix(8).lowercased(),
            meetingId: bundle.meeting.id,
            destinationVault: destinationVault,
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
        
        try store.saveOutboxItem(item)
        return item
    }
    
    // MARK: - Process Pending Outbox Items
    
    @discardableResult
    public func processPending() async -> [OutboxItem] {
        let pending = store.listOutboxItems(meetingId: nil, status: .pending)
        let retryable = store.listOutboxItems(meetingId: nil, status: .failedRetryable)
        let allEligible = pending + retryable
        
        var processed: [OutboxItem] = []
        let now = Date()
        
        for var item in allEligible {
            // Check exponential backoff
            if item.status == .failedRetryable, let last = item.lastAttemptAt {
                let backoffSeconds = min(60.0, baseBackoff * pow(2.0, Double(min(item.retryCount, 6))))
                if now.timeIntervalSince(last) < backoffSeconds {
                    continue // Skip until backoff window passes
                }
            }
            
            // Mark sending
            item.status = .sending
            try? store.saveOutboxItem(item)
            
            guard let payloadData = item.payloadJson.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(PrismMeetingPayload.self, from: payloadData) else {
                item.status = .conflict
                item.errorMessage = "Failed to parse stored payload JSON"
                item.lastAttemptAt = Date()
                try? store.saveOutboxItem(item)
                processed.append(item)
                continue
            }
            
            let baseRev = item.sourceRevision > 1 ? item.sourceRevision - 1 : nil
            
            do {
                let receipt = try await client.uploadMeeting(
                    payload: payload,
                    destinationVault: item.destinationVault,
                    idempotencyKey: item.idempotencyKey,
                    baseRevision: baseRev
                )
                item.status = .synced
                item.receipt = receipt
                item.errorMessage = nil
                item.lastAttemptAt = Date()
                try? store.saveOutboxItem(item)
            } catch let err as PrismError {
                item.lastAttemptAt = Date()
                switch err {
                case .needsSignIn:
                    item.status = .needsSignIn
                    item.errorMessage = err.localizedDescription
                case .forbidden:
                    item.status = .forbidden
                    item.errorMessage = err.localizedDescription
                case .conflict:
                    item.status = .conflict
                    item.errorMessage = err.localizedDescription
                case .failedRetryable:
                    item.retryCount += 1
                    item.status = .failedRetryable
                    item.errorMessage = err.localizedDescription
                case .invalidPayload, .unhandledResponse:
                    item.status = .conflict
                    item.errorMessage = err.localizedDescription
                }
                try? store.saveOutboxItem(item)
            } catch {
                item.lastAttemptAt = Date()
                item.retryCount += 1
                item.status = .failedRetryable
                item.errorMessage = error.localizedDescription
                try? store.saveOutboxItem(item)
            }
            
            processed.append(item)
        }
        
        return processed
    }
    
    // MARK: - Manual Retry & Cancellation
    
    public func retryItem(id: String) async throws -> OutboxItem {
        guard var item = store.getOutboxItem(id: id) else {
            throw PrismError.invalidPayload("Outbox item not found: \(id)")
        }
        
        item.status = .pending
        item.retryCount = 0
        item.errorMessage = nil
        try store.saveOutboxItem(item)
        
        guard let payloadData = item.payloadJson.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PrismMeetingPayload.self, from: payloadData) else {
            throw PrismError.invalidPayload("Failed to parse stored payload JSON")
        }
        
        let baseRev = item.sourceRevision > 1 ? item.sourceRevision - 1 : nil
        do {
            let receipt = try await client.uploadMeeting(
                payload: payload,
                destinationVault: item.destinationVault,
                idempotencyKey: item.idempotencyKey,
                baseRevision: baseRev
            )
            item.status = .synced
            item.receipt = receipt
            item.errorMessage = nil
            item.lastAttemptAt = Date()
            try store.saveOutboxItem(item)
            return item
        } catch let err as PrismError {
            item.lastAttemptAt = Date()
            switch err {
            case .needsSignIn:
                item.status = .needsSignIn
            case .forbidden:
                item.status = .forbidden
            case .conflict:
                item.status = .conflict
            case .failedRetryable:
                item.retryCount += 1
                item.status = .failedRetryable
            case .invalidPayload, .unhandledResponse:
                item.status = .conflict
            }
            item.errorMessage = err.localizedDescription
            try store.saveOutboxItem(item)
            throw err
        } catch {
            item.lastAttemptAt = Date()
            item.retryCount += 1
            item.status = .failedRetryable
            item.errorMessage = error.localizedDescription
            try store.saveOutboxItem(item)
            throw error
        }
    }
    
    public func cancelItem(id: String) throws {
        guard var item = store.getOutboxItem(id: id) else {
            throw PrismError.invalidPayload("Outbox item not found: \(id)")
        }
        item.status = .revoked
        item.errorMessage = "Cancelled by user"
        try store.saveOutboxItem(item)
    }
}
