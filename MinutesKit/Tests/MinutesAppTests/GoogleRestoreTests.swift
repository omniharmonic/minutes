import Foundation
import Testing
import MinutesCore
import MinutesCalendar
@testable import MinutesApp

private final class RestoreGoogleCredentials: OAuthCredentialStore, @unchecked Sendable {
    var approvalRequired = false
    let saved: Bool
    init(saved: Bool) { self.saved = saved }
    func read(service: String, account: String) throws -> Data? {
        guard saved, service == "app.minutes.oauth.google-calendar" else { return nil }
        return Data(#"{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":9999999999,"scopes":["https://www.googleapis.com/auth/calendar.events.readonly","https://www.googleapis.com/auth/calendar.calendarlist.readonly"]}"#.utf8)
    }
    func readWithoutInteraction(service: String, account: String) throws -> Data? {
        if approvalRequired { throw OAuthError.keychainFailure(-25308) }
        return try read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}
private actor RestoreGoogleHTTP: GoogleHTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        count += 1
        return GoogleHTTPResponse(status: 200, data: Data(#"{"items":[]}"#.utf8))
    }
}
@MainActor struct GoogleRestoreTests {
    private func run(saved: Bool = true, provider: String? = nil, approvalRequired: Bool = false) async throws -> (AppState, Int) {
        let name = "google-restore-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        if let provider { prefs.set(provider, forKey: "calendarProvider") }
        let credentials = RestoreGoogleCredentials(saved: saved)
        credentials.approvalRequired = approvalRequired
        let http = RestoreGoogleHTTP()
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "fixture.apps.googleusercontent.com"), credentialStore: credentials, transport: http)
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: prefs)
        await state.restoreGoogleCalendar(connection: connection)
        await state.restoreGoogleCalendar(connection: connection)
        return (state, await http.count)
    }
    @Test func startupResumesSavedGrantOnceAndFetchesEvents() async throws {
        let (state, count) = try await run()
        #expect(state.googleConnected && state.calendarConnected)
        #expect(state.calendarSource == .google)
        #expect(count == 1)
        #expect(!state.googleConnecting)
    }
    @Test func explicitDisconnectIsRespected() async throws {
        let (state, count) = try await run(provider: "none")
        #expect(!state.googleConnected)
        #expect(count == 0)
    }
    @Test func appleSelectionIsRespected() async throws {
        let (state, count) = try await run(provider: "apple")
        #expect(!state.googleConnected)
        #expect(count == 0)
    }
    @Test func missingGrantNeverOpensBrowserOrFetches() async throws {
        let (state, count) = try await run(saved: false)
        #expect(!state.googleConnected)
        #expect(count == 0)
    }
    @Test func startupDoesNotWaitForKeychainApproval() async throws {
        let (state, count) = try await run(approvalRequired: true)
        #expect(!state.googleConnected && !state.googleConnecting)
        #expect(count == 0)
        #expect(state.googleMessage.contains("Reconnect Saved Account"))
    }
}
