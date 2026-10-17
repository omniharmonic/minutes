import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

private final class ContractCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { items[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { items[service + "|" + account] = data } }
    func delete(service: String, account: String) throws { lock.withLock { _ = items.removeValue(forKey: service + "|" + account) } }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_PRISM_CONTRACT_URL"] != nil,
                "Opt-in: run audit/integrations/run-prism-contract.py against synthetic loopback Prism"))
struct PrismHTTPContractTests {
    @Test func actualPrismCommitsInitialAndEditedRevisionsWithRestrictedGrant() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawOrigin = try #require(env["MINUTES_PRISM_CONTRACT_URL"])
        let origin = try #require(URL(string: rawOrigin))
        // Never let this opt-in test target a remote deployment or a real vault.
        #expect(origin.scheme == "http")
        #expect(origin.host == "127.0.0.1")
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.path.isEmpty, origin.query == nil, origin.user == nil else {
            throw PrismConnectionError.invalidOrigin
        }
        let tokenFile = try #require(env["MINUTES_PRISM_CONTRACT_TOKENFILE"])
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = ContractCredentials()
        try credentials.write(Data(token.utf8), service: "app.minutes.oauth.prism-integration", account: origin.absoluteString)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-http-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("fixture.sqlite").path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connection = try PrismConnection(origin: origin, store: store, credentialStore: credentials, session: session)
        let capabilities = try await connection.verifyCapabilities()
        #expect(capabilities.restricted)
        #expect(capabilities.clientId == "minutes-native")
        #expect(capabilities.vaults.map(\.id) == ["primary"])
        #expect(try await connection.status().verified)
        var meeting = Meeting(id: "swift-contract-" + UUID().uuidString.lowercased(), title: "Synthetic Swift contract", userNotes: "Notes written by the user")
        try store.saveMeeting(meeting)
        let summary = MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "Synthetic outcome",
                                     decisions: ["Ship the fixture"], markdown: "# Synthetic summary\n\nShip the fixture.")
        func bundle() -> MeetingExportBundle {
            MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [
                Utterance(id: 1, meetingId: meeting.id, clusterId: "synthetic-cluster", speakerName: "Speaker 1", start: 0, end: 1, text: "Synthetic statement.")
            ], summary: summary)
        }
        let first = try await connection.enqueueNextRevision(bundle: bundle(), destinationVault: "primary")
        #expect(first.sourceRevision == 1)
        let firstResults = try await connection.syncPending()
        let initial = try #require(firstResults.first(where: { $0.id == first.id }))
        #expect(initial.status == .synced)
        let initialReceipt = try #require(initial.receipt)
        #expect(initialReceipt.serverRevision > 0)
        #expect(!initialReceipt.meetingNoteId.isEmpty && !initialReceipt.transcriptNoteId.isEmpty)
        #expect(try await connection.enqueueNextRevision(bundle: bundle(), destinationVault: "primary").id == first.id)
        #expect(try await connection.syncPending().isEmpty)
        meeting.userNotes = "Edited user notes"
        try store.saveMeeting(meeting)
        let second = try await connection.enqueueNextRevision(bundle: bundle(), destinationVault: "primary")
        #expect(second.sourceRevision == 2)
        #expect(second.baseServerRevision == initialReceipt.serverRevision)
        let secondResults = try await connection.syncPending()
        let edited = try #require(secondResults.first(where: { $0.id == second.id }))
        #expect(edited.status == .synced)
        let editedReceipt = try #require(edited.receipt)
        #expect(editedReceipt.serverRevision > initialReceipt.serverRevision)
        #expect(editedReceipt.importId != initialReceipt.importId)
        #expect(editedReceipt.meetingNoteId != initialReceipt.meetingNoteId)
        var receiptRequest = URLRequest(url: origin.appendingPathComponent("api/integrations/minutes/imports/" + editedReceipt.importId))
        receiptRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        receiptRequest.setValue("primary", forHTTPHeaderField: "X-Prism-Vault")
        let (receiptData, receiptResponse) = try await session.data(for: receiptRequest)
        #expect((receiptResponse as? HTTPURLResponse)?.statusCode == 200)
        let receiptObject = try #require(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
        #expect(receiptObject["status"] as? String == "committed")
        #expect(receiptObject["serverRevision"] as? Int == editedReceipt.serverRevision)
        var genericRequest = URLRequest(url: origin.appendingPathComponent("api/notes"))
        genericRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (_, genericResponse) = try await session.data(for: genericRequest)
        #expect((genericResponse as? HTTPURLResponse)?.statusCode == 403)
    }
}
