import Foundation
import Testing
import MinutesCore
@testable import MinutesExport

private final class VaultTestCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { items[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { items[service + "|" + account] = data } }
    func delete(service: String, account: String) throws { _ = lock.withLock { items.removeValue(forKey: service + "|" + account) } }
    var count: Int { lock.withLock { items.count } }
}

/// A scripted Parachute hub on `hub.invalid`, routed by method and path.
private final class FakeHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var log: [(String, String, Data?)] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); body = data
        }
        let (status, json) = Self.lock.withLock { Self.log.append((key, request.value(forHTTPHeaderField: "Authorization") ?? "", body)); return Self.routes[key] ?? (404, "{}") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(_ routes: [String: (Int, String)]) { lock.withLock { self.routes = routes; log = [] } }
    static func requests(_ key: String) -> [(String, String, Data?)] { lock.withLock { log.filter { $0.0 == key } } }
}

@Suite(.serialized) struct ParachuteVaultTests {
    private let metadata = #"{"issuer":"https://hub.invalid","authorization_endpoint":"https://hub.invalid/oauth/authorize","token_endpoint":"https://hub.invalid/oauth/token","registration_endpoint":"https://hub.invalid/oauth/register","revocation_endpoint":"https://hub.invalid/oauth/revoke"}"#

    private func connection(_ credentials: VaultTestCredentials) throws -> ParachuteVaultConnection {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakeHub.self]
        return try ParachuteVaultConnection(origin: URL(string: "https://Hub.invalid/vault/default")!, credentialStore: credentials, session: URLSession(configuration: config))
    }

    private func signIn(_ vault: ParachuteVaultConnection) async throws -> ParachuteVaultStatus {
        try await vault.connect { url, receiver, state in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(items.first { $0.name == "scope" }?.value == "vault:write")
            #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
            #expect(items.first { $0.name == "redirect_uri" }?.value == receiver.redirectURI.absoluteString)
            return URL(string: receiver.redirectURI.absoluteString + "?code=granted&state=" + state)!
        }
    }

    @Test("Addresses normalise to an https hub origin")
    func origins() throws {
        #expect(try ParachuteVaultConnection.normalizedOrigin("agent.example.com").absoluteString == "https://agent.example.com")
        #expect(try ParachuteVaultConnection.normalizedOrigin(" https://Agent.example.com:443/vault/default ").absoluteString == "https://agent.example.com")
        #expect(throws: ParachuteVaultError.invalidServer) { try ParachuteVaultConnection.normalizedOrigin("http://agent.example.com") }
        #expect(throws: ParachuteVaultError.invalidServer) { try ParachuteVaultConnection.normalizedOrigin("https://user:pw@agent.example.com") }
    }

    @Test("Sign-in registers once, keeps tokens in the credential store and learns the chosen vault")
    func signInFlow() async throws {
        FakeHub.reset([
            "GET /.well-known/oauth-authorization-server": (200, metadata),
            "POST /oauth/register": (201, #"{"client_id":"client-1"}"#),
            "POST /oauth/token": (200, #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":900,"scope":"vault:work:write","vault":"work"}"#),
            "GET /vault/work/api/notes": (200, "[]"),
        ])
        let credentials = VaultTestCredentials()
        let vault = try connection(credentials)
        let status = try await signIn(vault)
        #expect(status.vault == "work" && status.vaultURL.absoluteString == "https://hub.invalid/vault/work")
        _ = try await signIn(vault)
        #expect(FakeHub.requests("POST /oauth/register").count == 1)
        let token = String(decoding: try #require(FakeHub.requests("POST /oauth/token").first?.2), as: UTF8.self)
        #expect(token.contains("code_verifier=") && token.contains("grant_type=authorization_code"))
        _ = try await vault.verify()
        #expect(FakeHub.requests("GET /vault/work/api/notes").first?.1 == "Bearer at-1")
        #expect(try await vault.status()?.vault == "work")
        await vault.disconnect()
        #expect(try await vault.status() == nil)
    }

    @Test("A grant without a vault is revoked and reported")
    func noVault() async throws {
        FakeHub.reset([
            "GET /.well-known/oauth-authorization-server": (200, metadata),
            "POST /oauth/register": (201, #"{"client_id":"client-1"}"#),
            "POST /oauth/token": (200, #"{"access_token":"at-1","expires_in":900,"scope":"vault:read vault:write"}"#),
            "POST /oauth/revoke": (200, "{}"),
        ])
        let vault = try connection(VaultTestCredentials())
        await #expect(throws: ParachuteVaultError.noVaultGranted) { _ = try await signIn(vault) }
        #expect(FakeHub.requests("POST /oauth/revoke").count == 1)
    }

    @Test("Notes are created, then updated in place without overwriting vault edits; expired tokens refresh")
    func saveNotes() async throws {
        FakeHub.reset([
            "GET /.well-known/oauth-authorization-server": (200, metadata),
            "POST /oauth/register": (201, #"{"client_id":"client-1"}"#),
            "POST /oauth/token": (200, #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":0,"vault":"work"}"#),
            "POST /vault/work/api/notes": (201, #"{"id":"note-1","updatedAt":"2026-10-19T10:00:00Z"}"#),
            "PATCH /vault/work/api/notes/note-1": (409, #"{"message":"conflict"}"#),
        ])
        let vault = try connection(VaultTestCredentials())
        _ = try await signIn(vault)
        let receipt = try await vault.saveNote(path: "Meetings/2026-10-19 1000 Sync", content: "Body", tags: ["meeting"], metadata: ["minutes_meeting_id": "m1"], previous: nil)
        #expect(receipt == ParachuteNoteReceipt(id: "note-1", updatedAt: "2026-10-19T10:00:00Z"))
        // expires_in 0 forces a refresh before each request.
        let refreshes = FakeHub.requests("POST /oauth/token").compactMap { $0.2.map { String(decoding: $0, as: UTF8.self) } }.filter { $0.contains("grant_type=refresh_token") }
        #expect(!refreshes.isEmpty)
        await #expect(throws: ParachuteVaultError.editedInVault) {
            _ = try await vault.saveNote(path: "Meetings/x", content: "New", tags: [], metadata: [:], previous: receipt)
        }
        let patch = try #require(FakeHub.requests("PATCH /vault/work/api/notes/note-1").first?.2)
        let body = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(body["if_updated_at"] as? String == "2026-10-19T10:00:00Z" && body["force"] == nil)
    }

    @Test("Meeting notes get a readable path and Markdown without front matter or evidence ids")
    func noteShape() {
        var components = DateComponents(); components.year = 2026; components.month = 10; components.day = 19; components.hour = 9; components.minute = 5
        let meeting = Meeting(id: "m1", title: "Product / Tactical", startedAt: Calendar.current.date(from: components)!)
        #expect(ParachuteMeetingNote.path(folder: "/Meetings/../Work/", meeting: meeting) == "Meetings/Work/2026-10-19 0905 Product - Tactical")
        let utterance = Utterance(id: 1, meetingId: "m1", clusterId: "", speakerName: "Ana", start: 65, end: 70, text: "Ship it.")
        let summary = MeetingSummary(meetingId: "m1", title: meeting.title, overview: "", markdown: "- Ship Friday [T0001]")
        let content = ParachuteMeetingNote.content(bundle: .init(meeting: meeting, attendees: [], clusters: [], utterances: [utterance], summary: summary))
        #expect(!content.hasPrefix("---") && content.contains("- Ship Friday (1:05)") && content.contains("**Ana** (1:05): Ship it."))
    }
}
