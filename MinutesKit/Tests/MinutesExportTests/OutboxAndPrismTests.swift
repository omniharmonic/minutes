import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesExport

// MARK: - Mock URLProtocol for Real URLSession Stack Testing

final class MockPrismURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _handler = newValue
        }
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockPrismURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No handler registered"]))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

@Suite("Prism & Outbox Tests", .serialized)
struct OutboxAndPrismTests {
    
    @Test func customDirectoryPersistsInQueuedPayloadAndRejectsTraversal() throws {
        let (store, _, _, outbox, path) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = sampleBundle()
        try store.saveMeeting(original.meeting)
        let bundle = MeetingExportBundle(meeting: original.meeting, attendees: original.attendees,
            clusters: original.clusters, utterances: original.utterances, summary: original.summary,
            destinationDirectory: "Meetings/Work")
        let item = try outbox.enqueueNextRevision(bundle: bundle, destinationVault: "staging")
        let payload = try JSONDecoder().decode(PrismMeetingPayload.self, from: Data(item.payloadJson.utf8))
        #expect(payload.destinationDirectory == "Meetings/Work")
        #expect(try outbox.enqueueNextRevision(bundle: bundle, destinationVault: "staging").id == item.id)
        for invalid in ["", "/absolute", "../private", "a/../b", "a//b", "a/.hidden", "a\\b"] {
            #expect(throws: (any Error).self) { try PrismExportDirectory.validate(invalid) }
        }
    }

    @Test func markdownSaveDocumentMatchesCLIExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = sampleBundle()
        let result = try await MarkdownAdapter(outputDirectory: directory.path).export(bundle: bundle)
        let saved = try String(contentsOfFile: #require(result.pathOrURL), encoding: .utf8)
        #expect(saved == MarkdownAdapter.render(bundle: bundle))
        #expect(saved.contains(bundle.utterances[0].text))
        #expect(saved.contains(bundle.meeting.userNotes!))
    }

    private func createTestEnvironment() throws -> (MinutesStore, URLSession, PrismClient, OutboxManager, String) {
        let tempDb = (NSTemporaryDirectory() as NSString).appendingPathComponent("test_outbox_\(UUID().uuidString).sqlite")
        let store = try MinutesStore(dbPath: tempDb)
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPrismURLProtocol.self]
        let session = URLSession(configuration: config)
        
        let client = PrismClient(
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            session: session,
            tokenProvider: { "valid-test-bearer-token" }
        )
        
        let outbox = OutboxManager(
            store: store,
            client: client,
            maxRetries: 3,
            baseBackoff: 0.05
        )
        
        return (store, session, client, outbox, tempDb)
    }
    
    private func sampleBundle() -> MeetingExportBundle {
        let meeting = Meeting(
            id: "meet-\(UUID().uuidString.prefix(6))",
            title: "Q4 Roadmap Review",
            startedAt: Date(timeIntervalSince1970: 1728900000),
            endedAt: Date(timeIntervalSince1970: 1728901800),
            status: "finalized",
            userNotes: "Discussed mobile release timeline and Parachute sync."
        )
        let person = Person(id: "p1", displayName: "Sarah Chen", emails: ["sarah@example.com"])
        let cluster = SpeakerCluster(meetingId: meeting.id, trackId: "t1", label: "Sarah Chen")
        let utterance = Utterance(
            id: 1,
            meetingId: meeting.id,
            clusterId: cluster.id,
            speakerName: "Sarah Chen",
            start: 1.0,
            end: 5.0,
            text: "Let us ensure the outbox is completely crash-safe."
        )
        let summary = MeetingSummary(
            meetingId: meeting.id,
            title: meeting.title,
            overview: "Roadmap discussion",
            decisions: ["Approve outbox architecture"],
            actionItems: [ActionItem(text: "Verify with integration tests", owner: "Sarah")],
            markdown: "## Decisions\n- Approve outbox architecture"
        )
        return MeetingExportBundle(
            meeting: meeting,
            attendees: [person],
            clusters: [cluster],
            utterances: [utterance],
            summary: summary
        )
    }
    
    @Test("Enqueueing meeting creates durable pending record with canonical idempotency key")
    func testEnqueueCreatesDurablePendingRecord() throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "engineering-vault", sourceRevision: 1)
        
        #expect(item.status == .pending)
        #expect(item.meetingId == bundle.meeting.id)
        #expect(item.destinationVault == "engineering-vault")
        #expect(!item.idempotencyKey.isEmpty)
        #expect(item.retryCount == 0)
        
        // Verify persisted directly in SQLite
        let loaded = store.getOutboxItem(id: item.id)
        #expect(loaded != nil)
        #expect(loaded?.idempotencyKey == item.idempotencyKey)
        #expect(loaded?.status == .pending)
    }
    
    @Test("Successful upload transitions to .synced and stores PrismReceipt")
    func testSuccessfulUploadStoresReceiptAndTransitionsToSynced() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        
        MockPrismURLProtocol.requestHandler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer valid-test-bearer-token")
            #expect(req.value(forHTTPHeaderField: "X-Prism-Vault") == "default")
            #expect(req.value(forHTTPHeaderField: "Idempotency-Key") == item.idempotencyKey)
            
            let json = """
            {
                "status": "committed",
                "importId": "imp-9988",
                "meetingNoteId": "note-meeting-123",
                "transcriptNoteId": "note-transcript-123",
                "serverRevision": 1,
                "viewUrl": "http://127.0.0.1:3000/vault/default/meetings/123",
                "warnings": []
            }
            """
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (res, Data(json.utf8))
        }
        
        let processed = try await outbox.processPending()
        #expect(processed.count == 1)
        #expect(processed[0].status == .synced)
        #expect(processed[0].receipt?.importId == "imp-9988")
        #expect(processed[0].receipt?.meetingNoteId == "note-meeting-123")
        
        // Check SQLite
        let fromDb = store.getOutboxItem(id: item.id)
        #expect(fromDb?.status == .synced)
        #expect(fromDb?.receipt?.importId == "imp-9988")
    }
    
    @Test("503 Service Unavailable transitions item to .failedRetryable with incremented count")
    func testRetryableFailureTransitionsToFailedRetryable() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        
        MockPrismURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: [:])!
            return (res, Data("{\"error\": \"Database locked\"}".utf8))
        }
        
        let processed = try await outbox.processPending()
        #expect(processed.count == 1)
        #expect(processed[0].status == .failedRetryable)
        #expect(processed[0].retryCount == 1)
        #expect(processed[0].errorMessage?.contains("503") == true)
        
        let fromDb = store.getOutboxItem(id: item.id)
        #expect(fromDb?.status == .failedRetryable)
        #expect(fromDb?.retryCount == 1)
    }
    
    @Test("409 Conflict transitions item to .conflict without overwriting local state")
    func testConflict409TransitionsToConflict() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        
        MockPrismURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (res, Data("{\"error\": \"Conflict\", \"serverRevision\": 4}".utf8))
        }
        
        let processed = try await outbox.processPending()
        #expect(processed.count == 1)
        #expect(processed[0].status == .conflict)
        #expect(processed[0].errorMessage?.contains("Conflict") == true)
        
        let fromDb = store.getOutboxItem(id: item.id)
        #expect(fromDb?.status == .conflict)
    }
    
    @Test("401 Unauthorized transitions item to .needsSignIn")
    func testUnauthorized401TransitionsToNeedsSignIn() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        
        MockPrismURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!
            return (res, Data("{\"error\": \"Token expired\"}".utf8))
        }
        
        let processed = try await outbox.processPending()
        #expect(processed.count == 1)
        #expect(processed[0].status == .needsSignIn)
        
        let fromDb = store.getOutboxItem(id: item.id)
        #expect(fromDb?.status == .needsSignIn)
    }
    
    @Test("403 Forbidden transitions item to .forbidden")
    func testForbidden403TransitionsToForbidden() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "restricted-vault", sourceRevision: 1)
        
        MockPrismURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
            return (res, Data("{\"error\": \"Vault access denied\"}".utf8))
        }
        
        let processed = try await outbox.processPending()
        #expect(processed.count == 1)
        #expect(processed[0].status == .forbidden)
        
        let fromDb = store.getOutboxItem(id: item.id)
        #expect(fromDb?.status == .forbidden)
    }
    
    @Test("Idempotency deduplication prevents duplicate outbox entries")
    func testIdempotencyDeduplicationOnRepeatEnqueue() throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        
        let item1 = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        let item2 = try outbox.enqueue(bundle: bundle, destinationVault: "default", sourceRevision: 1)
        
        #expect(item1.id == item2.id)
        
        let items = store.listOutboxItems(meetingId: bundle.meeting.id, status: nil)
        #expect(items.count == 1)
    }
    @Test("Edited transcript text is never deduplicated by unchanged utterance count")
    func editedTranscriptGetsNewKey() throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let first = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        var utterances = bundle.utterances
        utterances[0].text = "Corrected transcript content"
        let edited = MeetingExportBundle(meeting: bundle.meeting, attendees: bundle.attendees,
            clusters: bundle.clusters, utterances: utterances, summary: bundle.summary)
        let second = try outbox.enqueue(bundle: edited, destinationVault: "default")
        #expect(first.id != second.id)
        #expect(first.idempotencyKey != second.idempotencyKey)
    }

    @Test("Separate destination vaults have independent durable deliveries")
    func separateVaultsGetSeparateDeliveries() throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let first = try outbox.enqueue(bundle: bundle, destinationVault: "one")
        let second = try outbox.enqueue(bundle: bundle, destinationVault: "two")
        #expect(first.id != second.id)
        #expect(second.destinationVault == "two")
    }

    @Test("Unassigned speakers are not exported as confirmed person identities")
    func unassignedSpeakerRemainsUnassigned() throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        let payload = try JSONDecoder().decode(PrismMeetingPayload.self, from: Data(item.payloadJson.utf8))
        #expect(payload.utterances[0].speakerPersonId == nil)
        #expect(payload.utterances[0].assignment == "unassigned")
        #expect(payload.people[0].attendance == "invited")
    }

    @Test("HTTP 202 acceptance does not claim committed sync")
    func pendingResponseIsNotSynced() async throws {
        let (store, _, _, outbox, dbPath) = try createTestEnvironment()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let bundle = sampleBundle()
        try store.saveMeeting(bundle.meeting)
        let item = try outbox.enqueue(bundle: bundle, destinationVault: "default")
        MockPrismURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"status":"pending","importId":"imp-pending"}"#.utf8))
        }
        let processed = try await outbox.processPending()
        #expect(processed.first?.status == .awaitingReceipt)
        #expect(store.getOutboxItem(id: item.id)?.receipt == nil)
    }

}
