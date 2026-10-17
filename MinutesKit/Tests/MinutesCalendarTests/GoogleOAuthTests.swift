import Foundation
import Testing
import MinutesCore
@testable import MinutesCalendar

struct GoogleOAuthTests {
    @Test("PKCE uses the RFC7636 S256 vector and validates redirect/state without duplicates")
    func pkceValidation() throws {
        let attempt = try OAuthPKCEAttempt(clientID: "public.apps.googleusercontent.com", redirectURI: URL(string: "com.example.app:/oauth2redirect")!, scopes: ["calendar"], verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "random-state")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(try attempt.authorizationCode(from: URL(string: "com.example.app:/oauth2redirect?state=random-state&code=code")!) == "code")
        #expect(throws: (any Error).self) { try attempt.authorizationCode(from: URL(string: "com.example.app:/oauth2redirect?state=wrong&code=code")!) }
        #expect(throws: (any Error).self) { try attempt.authorizationCode(from: URL(string: "com.example.app:/oauth2redirect?state=random-state&state=random-state&code=code")!) }
        #expect(throws: (any Error).self) { try attempt.authorizationCode(from: URL(string: "com.evil.app:/oauth2redirect?state=random-state&code=code")!) }
    }

    @Test("Public Google configuration rejects secret-bearing metadata")
    func publicConfigurationOnly() throws {
        let data = Data(#"{"desktopClientID":"public.apps.googleusercontent.com","client_secret":"do-not-store"}"#.utf8)
        #expect(throws: (any Error).self) { try GoogleCalendarConfiguration.decodePublicMetadata(data) }
        #expect(try GoogleCalendarConfiguration.decodePublicMetadata(Data(#"{"desktopClientID":"public.apps.googleusercontent.com"}"#.utf8)).calendarIDs == ["primary"])
    }
}

private final class MemoryGoogleCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func delete(service: String, account: String) throws { lock.withLock { values.removeValue(forKey: service + account); () } }
}
private actor ScriptedGoogleHTTP: GoogleHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [GoogleHTTPResponse]
    init(_ responses: [GoogleHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw OAuthError.invalidResponse }
        return responses.removeFirst()
    }
}
@MainActor private final class FixtureGoogleAgent: GoogleOAuthUserAgent {
    let platform: GoogleOAuthPlatform = .desktop
    let badState: Bool
    init(badState: Bool = false) { self.badState = badState }
    func prepareRedirect(configuration: GoogleCalendarConfiguration) async throws -> URL { URL(string: "http://127.0.0.1:12345/oauth2callback")! }
    func authorize(url: URL, redirectURI: URL) async throws -> URL {
        let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!.split(separator: " ").map(String.init)
        #expect(Set(requested) == Set(["https://www.googleapis.com/auth/calendar.events.readonly", "https://www.googleapis.com/auth/calendar.calendarlist.readonly"]))
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: badState ? "wrong" : state), .init(name: "code", value: "fixture-code")]
        return callback.url!
    }
}
private func googleResponse(_ json: String, status: Int = 200) -> GoogleHTTPResponse { GoogleHTTPResponse(status: status, data: Data(json.utf8)) }
private let googleToken = #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly"}"#

extension GoogleOAuthTests {
    @Test @MainActor func exchangePaginationAndMapping() async throws {
        let transport = ScriptedGoogleHTTP([
            googleResponse(googleToken),
            googleResponse(#"{"nextPageToken":"next/page","items":[{"id":"one","summary":"Planning","start":{"dateTime":"2026-10-14T10:00:00-06:00"},"end":{"dateTime":"2026-10-14T11:00:00-06:00"},"attendees":[{"email":"INVITEE@example.com","displayName":"Invitee","responseStatus":"tentative","self":true}],"organizer":{"email":"organizer@example.com"},"hangoutLink":"https://meet.google.com/abc-defg-hij"}]}"#),
            googleResponse(#"{"items":[{"id":"all-day","start":{"date":"2026-10-14"},"end":{"date":"2026-10-15"}},{"id":"cancelled","status":"cancelled"}]}"#)
        ])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com", calendarIDs: ["team@example.com/one"]), credentialStore: MemoryGoogleCredentials(), transport: transport)
        try await connection.connect(using: FixtureGoogleAgent())
        let formatter = ISO8601DateFormatter()
        let events = try await connection.events(in: DateInterval(start: formatter.date(from: "2026-10-14T00:00:00Z")!, duration: 86400))
        #expect(events.count == 1)
        #expect(events.first?.attendees.first?.isCurrentUser == true)
        #expect(events.first?.attendees.first?.responseStatus == "tentative")
        #expect(events.first?.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(events.first?.calendarIdentifier == "google:team@example.com/one")
        let requests = await transport.requests
        let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
        #expect(body.contains("code_verifier=")); #expect(!body.contains("client_secret"))
        #expect(requests[1].url!.absoluteString.contains("team%40example.com%2Fone"))
        #expect(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "pageToken", value: "next/page")) == true)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
    }
    @Test @MainActor func mismatchNeverExchangesCode() async throws {
        let http = ScriptedGoogleHTTP([])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        await #expect(throws: (any Error).self) { try await connection.connect(using: FixtureGoogleAgent(badState: true)) }
        #expect(await http.requests.isEmpty)
        #expect(try await connection.status().connected == false)
    }
    @Test @MainActor func refreshPreservesRefreshTokenAndRevokes() async throws {
        let http = ScriptedGoogleHTTP([googleResponse(googleToken), googleResponse("", status: 401), googleResponse(#"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#), googleResponse(#"{"items":[]}"#), googleResponse("")])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        try await connection.connect(using: FixtureGoogleAgent())
        _ = try await connection.calendars()
        try await connection.disconnect()
        let requests = await http.requests
        #expect(String(decoding: requests[2].httpBody!, as: UTF8.self).contains("refresh_token=fixture-refresh"))
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        #expect(String(decoding: requests[4].httpBody!, as: UTF8.self) == "token=fixture-refresh")
        #expect(try await connection.status().connected == false)
    }
    @Test @MainActor func revokedRefreshClearsCredentialsAndPaginationCyclesFail() async throws {
        let http = ScriptedGoogleHTTP([googleResponse(googleToken), googleResponse("", status: 401), googleResponse(#"{"error":"invalid_grant"}"#, status: 400)])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        try await connection.connect(using: FixtureGoogleAgent())
        await #expect(throws: (any Error).self) { try await connection.calendars() }
        #expect(try await connection.status().connected == false)
        let cyclic = ScriptedGoogleHTTP([googleResponse(googleToken), googleResponse(#"{"nextPageToken":"same"}"#), googleResponse(#"{"nextPageToken":"same"}"#)])
        let other = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: cyclic)
        try await other.connect(using: FixtureGoogleAgent())
        await #expect(throws: (any Error).self) { try await other.calendars() }
        #expect(await cyclic.requests.count == 3)
    }
}

private actor PausedGoogleHTTP: GoogleHTTPTransport {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<GoogleHTTPResponse, any Error>?
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        started = true; waiters.forEach { $0.resume() }; waiters = []
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func complete() { pending?.resume(returning: googleResponse(googleToken)); pending = nil }
}
extension GoogleOAuthTests {
    @Test @MainActor func disconnectCannotResurrectInflightConnection() async throws {
        let http = PausedGoogleHTTP()
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        let signIn = Task { try await connection.connect(using: FixtureGoogleAgent()) }
        await http.waitUntilStarted()
        try await connection.disconnect(revoke: false)
        await http.complete()
        await #expect(throws: (any Error).self) { try await signIn.value }
        #expect(try await connection.status().connected == false)
    }
}

extension GoogleOAuthTests {
    @Test @MainActor func partialGrantFailsClosed() async throws {
        let http = ScriptedGoogleHTTP([googleResponse(#"{"access_token":"partial","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/calendar.events.readonly"}"#)])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        await #expect(throws: (any Error).self) { try await connection.connect(using: FixtureGoogleAgent()) }
        #expect(try await connection.status().connected == false)
    }
}

extension GoogleOAuthTests {
    @Test @MainActor func desktopRegistrationIsUsedForExchangeAndRefreshOnly() async throws {
        let credentials = MemoryGoogleCredentials()
        let client = "public.apps.googleusercontent.com"
        try credentials.write(Data(#"{"clientID":"public.apps.googleusercontent.com","clientSecret":"fixture-desktop-registration"}"#.utf8), service: "app.minutes.oauth.google-desktop-client", account: client)
        let http = ScriptedGoogleHTTP([googleResponse(googleToken), googleResponse("", status: 401), googleResponse(googleToken), googleResponse(#"{"items":[]}"#), googleResponse("")])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: client), credentialStore: credentials, transport: http)
        try await connection.connect(using: FixtureGoogleAgent())
        _ = try await connection.calendars()
        try await connection.disconnect()
        let requests = await http.requests
        #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("client_secret=fixture-desktop-registration"))
        #expect(String(decoding: requests[2].httpBody!, as: UTF8.self).contains("client_secret=fixture-desktop-registration"))
        #expect(!String(decoding: requests[4].httpBody!, as: UTF8.self).contains("client_secret"))
        #expect(try credentials.read(service: "app.minutes.oauth.google-desktop-client", account: client) != nil)
    }
}

extension GoogleOAuthTests {
    @Test @MainActor func registrationErrorsGiveSetupGuidanceWithoutEchoingResponse() async throws {
        let http = ScriptedGoogleHTTP([googleResponse(#"{"error":"invalid_request","error_description":"client_secret is missing; fixture-sensitive-diagnostic"}"#, status: 400)])
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "public.apps.googleusercontent.com"), credentialStore: MemoryGoogleCredentials(), transport: http)
        do {
            try await connection.connect(using: FixtureGoogleAgent())
            Issue.record("Expected registration error")
        } catch OAuthError.desktopRegistrationRequired {
            #expect(!OAuthError.desktopRegistrationRequired.localizedDescription.contains("fixture-sensitive-diagnostic"))
        }
    }
}
