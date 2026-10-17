import Foundation
import Testing
import MinutesCore
import MinutesCalendar
@testable import MinutesApp

private final class ResponsiveGoogleCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: Data? = Data(#"{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":9999999999,"scopes":["https://www.googleapis.com/auth/calendar.events.readonly","https://www.googleapis.com/auth/calendar.calendarlist.readonly"]}"#.utf8)
    func read(service: String, account: String) throws -> Data? { lock.withLock { saved } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { saved = data } }
    func delete(service: String, account: String) throws { lock.withLock { saved = nil } }
}
private actor SuspendedGoogleEvents: GoogleHTTPTransport {
    private var pending: [CheckedContinuation<GoogleHTTPResponse, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var eventRequests = 0
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        if request.url?.path == "/revoke" { return GoogleHTTPResponse(status: 200, data: Data()) }
        eventRequests += 1
        waiter?.resume(); waiter = nil
        return await withCheckedContinuation { pending.append($0) }
    }
    func waitForEvent() async { if eventRequests > 0 { return }; await withCheckedContinuation { waiter = $0 } }
    func finish() { for continuation in pending { continuation.resume(returning: GoogleHTTPResponse(status: 200, data: Data(#"{"items":[]}"#.utf8))) }; pending = [] }
}
@MainActor struct GoogleRefreshResponsivenessTests {
    @Test func slowInitialRefreshDoesNotLockDisconnectOrMultiplyTimerRequests() async throws {
        let prefsID = "minutes-google-responsive-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: prefsID))
        defer { prefs.removePersistentDomain(forName: prefsID) }
        let http = SuspendedGoogleEvents()
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: "fixture.apps.googleusercontent.com"),
                                                  credentialStore: ResponsiveGoogleCredentials(), transport: http)
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: prefs)
        let resume = Task { await state.resumeGoogleCalendar(connection: connection, allowInteraction: false) }
        await http.waitForEvent()
        #expect(state.googleConnected)
        #expect(!state.googleConnecting)
        #expect(state.googleMessage.contains("Refreshing"))
        state.refreshCalendar(); state.refreshCalendar(); state.refreshCalendar()
        for _ in 0..<30 { await Task.yield() }
        #expect(await http.eventRequests == 1)
        await state.disconnectGoogleCalendar()
        #expect(!state.googleConnected && !state.googleConnecting)
        await http.finish(); await resume.value
        #expect(!state.googleConnected && !state.calendarConnected)
        #expect(state.upcomingEvents.isEmpty)
        #expect(state.googleMessage.contains("removed"))
    }
}
