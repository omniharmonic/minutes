import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

@Suite(.serialized) struct PrismConnectionTests {
    @Test func rejectsUnsecuredOrPathOrigins() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("fixture.sqlite").path)
        for raw in ["http://remote.example", "https://user:password@prism.example", "https://prism.example/path", "https://prism.example?token=bad"] {
            #expect(throws: (any Error).self) { try PrismConnection(origin: URL(string: raw)!, store: store) }
        }
    }
    @Test func capabilityContractFailsClosed() throws {
        #expect(throws: (any Error).self) { try PrismMinutesCapabilities.decodeValidated(Data(#"{"schemaVersions":[1],"vaults":[{"id":"vault"}]}"#.utf8)) }
        let valid = Data(#"{"integration":"minutes","clientId":"minutes-native","restricted":true,"schemaVersions":[1],"operations":["meetings:write","imports:read"],"vaults":[{"id":"staging","name":"Staging"}]}"#.utf8)
        #expect(try PrismMinutesCapabilities.decodeValidated(valid).vaults.first?.id == "staging")
        let owner = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "minutes-native", with: "prism-native")
        #expect(throws: (any Error).self) { try PrismMinutesCapabilities.decodeValidated(Data(owner.utf8)) }
    }
}

private final class PrismTestCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { items[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { items[service + account] = data } }
    func delete(service: String, account: String) throws { lock.withLock { items.removeValue(forKey: service + account); () } }
}
private final class PrismAuthScript: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Data)] = []
    private var received: [URLRequest] = []
    func reset(_ replies: [(Int, String)]) { lock.withLock { self.replies = replies.map { ($0.0, Data($0.1.utf8)) }; received = [] } }
    func consume(_ request: URLRequest) -> (Int, Data) { lock.withLock { received.append(request); return replies.isEmpty ? (599, Data()) : replies.removeFirst() } }
    var requests: [URLRequest] { lock.withLock { received } }
}
private final class PrismAuthURLProtocol: URLProtocol, @unchecked Sendable {
    static let script = PrismAuthScript()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.script.consume(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class PrismFixtureBrowser: PrismBrowserAuthorizing {
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first(where: { $0.name == "client_id" })?.value == "minutes-native")
        #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(!url.absoluteString.contains("code_verifier"))
        let state = query.first(where: { $0.name == "state" })!.value!
        return URL(string: "minutes://auth/callback?state=\(state)&code=fixture-code")!
    }
}
private let prismTokenJSON = #"{"access_token":"pd_fixture_token_1234567890123456789","token_type":"Bearer"}"#
private let prismCapabilitiesJSON = #"{"integration":"minutes","clientId":"minutes-native","restricted":true,"schemaVersions":[1],"operations":["meetings:write","imports:read"],"vaults":[{"id":"staging","name":"Staging"}]}"#
extension PrismConnectionTests {
    @Test @MainActor func unavailableCapabilitiesNeverSaveMintedToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("fixture.sqlite").path)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrismAuthURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        PrismAuthURLProtocol.script.reset([(200, prismTokenJSON), (404, ""), (200, "")])
        let connection = try PrismConnection(origin: URL(string: "https://fixture.invalid")!, store: store, credentialStore: PrismTestCredentials(), session: session)
        await #expect(throws: (any Error).self) { try await connection.connect(using: PrismFixtureBrowser()) }
        #expect(try await connection.status().hasCredential == false)
        #expect(PrismAuthURLProtocol.script.requests.map { $0.url!.path } == ["/auth/device/token", "/api/integrations/minutes/capabilities", "/auth/device/revoke"])
    }
    @Test @MainActor func verifiedConnectionScopesQueueAndDisconnectsLocallyOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("fixture.sqlite").path)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrismAuthURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        PrismAuthURLProtocol.script.reset([(200, prismTokenJSON), (200, prismCapabilitiesJSON), (503, "")])
        let connection = try PrismConnection(origin: URL(string: "https://fixture.invalid:443/")!, store: store, credentialStore: PrismTestCredentials(), session: session)
        try await connection.connect(using: PrismFixtureBrowser())
        #expect(try await connection.status().verified)
        let meeting = Meeting(id: "fixture", title: "Synthetic meeting"); try store.saveMeeting(meeting)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil)
        await #expect(throws: (any Error).self) { try await connection.enqueue(bundle: bundle, destinationVault: "wrong") }
        let item = try await connection.enqueue(bundle: bundle, destinationVault: "staging")
        #expect(item.destinationOrigin == "https://fixture.invalid")
        #expect(await connection.outboxItems().count == 1)
        await #expect(throws: (any Error).self) { try await connection.disconnect() }
        #expect(try await connection.status().hasCredential == false)
        #expect(await connection.outboxItems().first?.status == .pending)
    }
}

extension PrismConnectionTests {
    @Test @MainActor func serverErrorBodyIsNotPersistedInOutboxDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("fixture.sqlite").path)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrismAuthURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        PrismAuthURLProtocol.script.reset([(200, prismTokenJSON), (200, prismCapabilitiesJSON), (200, prismCapabilitiesJSON), (403, "pd_secret_from_untrusted_server")])
        let connection = try PrismConnection(origin: URL(string: "https://fixture.invalid")!, store: store, credentialStore: PrismTestCredentials(), session: session)
        try await connection.connect(using: PrismFixtureBrowser())
        let meeting = Meeting(id: "fixture", title: "Synthetic meeting"); try store.saveMeeting(meeting)
        _ = try await connection.enqueue(bundle: MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil), destinationVault: "staging")
        let results = try await connection.syncPending()
        #expect(results.first?.status == .forbidden)
        #expect(results.first?.errorMessage?.contains("pd_secret") == false)
    }
}
extension PrismConnectionTests {
    @Test @MainActor func newAuthorizationCannotAdoptOldGrantQueue() async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrismAuthURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let secondToken = prismTokenJSON.replacingOccurrences(of: "1234567890123456789", with: "9876543210987654321")
        PrismAuthURLProtocol.script.reset([(200, prismTokenJSON), (200, prismCapabilitiesJSON), (200, secondToken), (200, prismCapabilitiesJSON), (200, prismCapabilitiesJSON)])
        let connection = try PrismConnection(origin: URL(string: "https://fixture.invalid")!, store: store, credentialStore: PrismTestCredentials(), session: session)
        try await connection.connect(using: PrismFixtureBrowser())
        let meeting = Meeting(id: "fixture", title: "Synthetic meeting"); try store.saveMeeting(meeting)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil)
        let old = try await connection.enqueueNextRevision(bundle: bundle, destinationVault: "staging")
        try await connection.connect(using: PrismFixtureBrowser())
        #expect(try await connection.syncPending().isEmpty)
        #expect(PrismAuthURLProtocol.script.requests.count == 5)
        let requeued = try await connection.enqueueNextRevision(bundle: bundle, destinationVault: "staging")
        #expect(old.grantFingerprint != requeued.grantFingerprint)
        #expect(old.idempotencyKey != requeued.idempotencyKey)
        #expect(requeued.sourceRevision == 1)
        #expect(store.getOutboxItem(id: old.id)?.status == .pending)
    }
}
extension PrismConnectionTests {
    @Test @MainActor func externallyReplacedCredentialCannotReuseOldVerifiedCapabilities() async throws {
        let store = try MinutesStore(dbPath: ":memory:")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PrismAuthURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let secondToken = prismTokenJSON.replacingOccurrences(of: "1234567890123456789", with: "9876543210987654321")
        PrismAuthURLProtocol.script.reset([(200, prismTokenJSON), (200, prismCapabilitiesJSON), (200, secondToken), (200, prismCapabilitiesJSON)])
        let credentials = PrismTestCredentials()
        let origin = URL(string: "https://fixture.invalid")!
        let old = try PrismConnection(origin: origin, store: store, credentialStore: credentials, session: session)
        let replacement = try PrismConnection(origin: origin, store: store, credentialStore: credentials, session: session)
        try await old.connect(using: PrismFixtureBrowser())
        try await replacement.connect(using: PrismFixtureBrowser())
        #expect(try await old.status().verified == false)
        let meeting = Meeting(id: "fixture", title: "Synthetic"); try store.saveMeeting(meeting)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: [], clusters: [], utterances: [], summary: nil)
        await #expect(throws: (any Error).self) { try await old.enqueueNextRevision(bundle: bundle, destinationVault: "staging") }
        #expect(store.listOutboxItems().isEmpty)
    }
}
