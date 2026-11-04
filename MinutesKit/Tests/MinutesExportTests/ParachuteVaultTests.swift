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

    private func signIn(_ vault: ParachuteVaultConnection, scope: String = "vault:write") async throws -> ParachuteVaultStatus {
        try await vault.connect { url, receiver, state in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(items.first { $0.name == "scope" }?.value == scope)
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

    @Test("Sign-in asks for the hub's default vault by name, so no all-vaults choice is offered")
    func signInNamesDefaultVault() async throws {
        FakeHub.reset([
            "GET /.well-known/oauth-authorization-server": (200, metadata),
            "GET /.well-known/parachute.json": (200, #"{"vaults":[{"name":"work"},{"name":"default"}]}"#),
            "POST /oauth/register": (201, #"{"client_id":"client-1"}"#),
            "POST /oauth/token": (200, #"{"access_token":"at-1","expires_in":900,"scope":"vault:default:write","vault":"default"}"#),
        ])
        let status = try await signIn(try connection(VaultTestCredentials()), scope: "vault:default:write")
        #expect(status.vault == "default")
        #expect(ParachuteVaultConnection.preferredVault(among: [], listed: ["only"]) == "only")
        #expect(ParachuteVaultConnection.preferredVault(among: [], listed: ["a", "b"]) == nil)
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
        #expect(ParachuteMeetingNote.path(folder: "/Meetings/../Work/", meeting: meeting) == "Meetings/Work/2026-10-19-product-tactical")
        #expect(ParachuteMeetingNote.path(folder: ParachuteMeetingNote.defaultFolder, meeting: Meeting(id: "m2", title: "Café — 1:1 ✨", startedAt: meeting.startedAt))
                == "vault/_inbox/transcripts/minutes/2026-10-19-cafe-1-1")
        #expect(ParachuteMeetingNote.slug("会议") == "meeting")
        var ended = meeting; ended.endedAt = meeting.startedAt.addingTimeInterval(1_800); ended.calendarEventId = "evt-1"
        let ana = Person(id: "p1", displayName: "Ana", emails: ["ana@example.com"])
        let values = ParachuteMeetingNote.metadata(bundle: .init(meeting: ended, attendees: [ana], clusters: [], utterances: [], summary: nil))
        #expect(values["attendees"] == ["Ana"] && values["attendeeEmails"] == ["ana@example.com"])
        #expect(values["date"] == "2026-10-19" && values["duration_minutes"] == 30 && values["type"] == "transcript")
        #expect(values["calendarEventId"] == "evt-1" && values["source"] == "minutes")
        #expect(ParachuteMeetingNote.tags.contains("transcript"))
        let utterance = Utterance(id: 1, meetingId: "m1", clusterId: "", speakerName: "Ana", start: 65, end: 70, text: "Ship it.")
        let summary = MeetingSummary(meetingId: "m1", title: meeting.title, overview: "", markdown: "- Ship Friday [T0001]")
        let content = ParachuteMeetingNote.content(bundle: .init(meeting: meeting, attendees: [], clusters: [], utterances: [utterance], summary: summary))
        #expect(!content.hasPrefix("---") && content.contains("- Ship Friday (1:05)") && content.contains("**Ana** (1:05): Ship it."))
    }

    // MARK: One note per meeting across devices

    private func signedInHub(_ extra: [String: (Int, String)]) async throws -> ParachuteVaultConnection {
        var routes: [String: (Int, String)] = [
            "GET /.well-known/oauth-authorization-server": (200, metadata),
            "POST /oauth/register": (201, #"{"client_id":"client-1"}"#),
            "POST /oauth/token": (200, #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":900,"vault":"work"}"#),
        ]
        routes.merge(extra) { _, new in new }
        FakeHub.reset(routes)
        let vault = try connection(VaultTestCredentials())
        _ = try await signIn(vault)
        return vault
    }

    private func noteJSON(id: String, content: String, hash: String?, tags: [String] = ["meeting"], updated: String = "2026-11-04T10:00:00Z") -> String {
        var metadata: [String: Any] = ["minutes_meeting_id": "m1", "source": "minutes"]
        if let hash { metadata["minutes_content_hash"] = hash }
        let object: [String: Any] = ["id": id, "path": "Meetings/x", "content": content, "tags": tags, "metadata": metadata, "updatedAt": updated]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func save(_ vault: ParachuteVaultConnection, _ content: String, previous: ParachuteNoteReceipt?) async throws -> ParachuteNoteReceipt {
        try await vault.saveNote(path: "Meetings/x", content: content, tags: ["meeting"],
                                 metadata: ["minutes_meeting_id": "m1", "minutes_content_hash": .text(ParachuteMeetingNote.contentHash(content))],
                                 previous: previous, meetingID: "m1")
    }

    @Test("A device without a receipt adopts the note another device created instead of making a second one")
    func adoptsExistingNote() async throws {
        let old = noteJSON(id: "note-1", content: "Old body", hash: ParachuteMeetingNote.contentHash("Old body"))
        let vault = try await signedInHub([
            "GET /vault/work/api/notes": (200, "[\(old)]"),
            "PATCH /vault/work/api/notes/note-1": (200, #"{"id":"note-1","updatedAt":"2026-11-04T11:00:00Z"}"#),
        ])
        let receipt = try await save(vault, "New body", previous: nil)
        #expect(receipt.id == "note-1")
        #expect(FakeHub.requests("POST /vault/work/api/notes").isEmpty)
        let patch = try #require(FakeHub.requests("PATCH /vault/work/api/notes/note-1").first?.2)
        let body = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(body["if_updated_at"] as? String == "2026-11-04T10:00:00Z")
    }

    @Test("A note an agent moved elsewhere is left where it is, even with its text unchanged")
    func movedNoteLeftAlone() async throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(noteJSON(id: "note-1", content: "Body", hash: ParachuteMeetingNote.contentHash("Body")).utf8)) as? [String: Any])
        object["path"] = "vault/projects/alpha/meetings/x"
        var metadata = try #require(object["metadata"] as? [String: Any]); metadata["minutes_path"] = "Meetings/x"; object["metadata"] = metadata
        let moved = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let vault = try await signedInHub(["GET /vault/work/api/notes": (200, "[\(moved)]")])
        await #expect(throws: ParachuteVaultError.editedInVault) { _ = try await save(vault, "New body", previous: nil) }
        #expect(FakeHub.requests("PATCH /vault/work/api/notes/note-1").isEmpty)
    }

    @Test("Updates never send a path, so a note is never moved; new notes record where they were put")
    func updatesDoNotMove() async throws {
        let old = noteJSON(id: "note-1", content: "Old body", hash: ParachuteMeetingNote.contentHash("Old body"))
        let vault = try await signedInHub([
            "GET /vault/work/api/notes": (200, "[\(old)]"),
            "PATCH /vault/work/api/notes/note-1": (200, #"{"id":"note-1","updatedAt":"2026-11-04T11:00:00Z"}"#),
        ])
        _ = try await save(vault, "New body", previous: nil)
        let patchData = try #require(FakeHub.requests("PATCH /vault/work/api/notes/note-1").first?.2)
        let patch = try #require(try JSONSerialization.jsonObject(with: patchData) as? [String: Any])
        #expect(patch["path"] == nil && (patch["metadata"] as? [String: Any])?["minutes_path"] == nil)

        let fresh = try await signedInHub(["POST /vault/work/api/notes": (201, #"{"id":"note-2","updatedAt":"2026-11-04T11:00:00Z"}"#)])
        _ = try await save(fresh, "Body", previous: nil)
        let postData = try #require(FakeHub.requests("POST /vault/work/api/notes").first?.2)
        let post = try #require(try JSONSerialization.jsonObject(with: postData) as? [String: Any])
        #expect((post["metadata"] as? [String: Any])?["minutes_path"] as? String == "Meetings/x")
    }

    @Test("An unchanged meeting is not written again")
    func skipsIdenticalNote() async throws {
        let same = noteJSON(id: "note-1", content: "Body", hash: ParachuteMeetingNote.contentHash("Body"))
        let vault = try await signedInHub(["GET /vault/work/api/notes": (200, "[\(same)]")])
        #expect(try await save(vault, "Body", previous: nil).id == "note-1")
        #expect(FakeHub.requests("PATCH /vault/work/api/notes/note-1").isEmpty && FakeHub.requests("POST /vault/work/api/notes").isEmpty)
    }

    @Test("A note found by meeting id that someone edited is left alone")
    func foundEditedNoteIsLeftAlone() async throws {
        let edited = noteJSON(id: "note-1", content: "Body plus an agent's notes", hash: ParachuteMeetingNote.contentHash("Body"))
        let vault = try await signedInHub(["GET /vault/work/api/notes": (200, "[\(edited)]")])
        await #expect(throws: ParachuteVaultError.editedInVault) { _ = try await save(vault, "New body", previous: nil) }
        #expect(FakeHub.requests("POST /vault/work/api/notes").isEmpty)
    }

    @Test("A conflict caused by another Minutes device is retried; one caused by an agent stops updates")
    func conflictOwnership() async throws {
        let receipt = ParachuteNoteReceipt(id: "note-1", updatedAt: "2026-11-04T09:00:00Z")
        // Another device wrote exactly what Minutes renders: retry with the new stamp.
        let fromDevice = noteJSON(id: "note-1", content: "Phone body", hash: ParachuteMeetingNote.contentHash("Phone body"))
        var vault = try await signedInHub([
            "PATCH /vault/work/api/notes/note-1": (409, #"{"error_type":"conflict"}"#),
            "GET /vault/work/api/notes/note-1": (200, fromDevice),
        ])
        await #expect(throws: (any Error).self) { _ = try await save(vault, "Mac body", previous: receipt) }
        let patches = FakeHub.requests("PATCH /vault/work/api/notes/note-1").compactMap(\.2)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(patches.count == 2 && patches[1]["if_updated_at"] as? String == "2026-11-04T10:00:00Z")

        // An agent added a tag: Minutes stops.
        let tagged = noteJSON(id: "note-1", content: "Phone body", hash: ParachuteMeetingNote.contentHash("Phone body"), tags: ["meeting", "followup"])
        vault = try await signedInHub([
            "PATCH /vault/work/api/notes/note-1": (409, #"{"error_type":"conflict"}"#),
            "GET /vault/work/api/notes/note-1": (200, tagged),
        ])
        await #expect(throws: ParachuteVaultError.editedInVault) { _ = try await save(vault, "Mac body", previous: receipt) }
        #expect(FakeHub.requests("PATCH /vault/work/api/notes/note-1").count == 1)
    }

    @Test("Content fingerprints ignore line endings and surrounding whitespace")
    func contentHashNormalizes() {
        #expect(ParachuteMeetingNote.contentHash("a\r\nb\n") == ParachuteMeetingNote.contentHash("a\nb"))
        #expect(ParachuteMeetingNote.contentHash("a") != ParachuteMeetingNote.contentHash("b"))
    }
}
