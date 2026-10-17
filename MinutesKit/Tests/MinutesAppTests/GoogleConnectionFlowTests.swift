import Foundation
import Testing
import MinutesCore
import MinutesCalendar
@testable import MinutesApp

private final class IsolatedGoogleStore: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var item: Data?
    func read(service: String, account: String) throws -> Data? { lock.withLock { item } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { item = data } }
    func delete(service: String, account: String) throws { lock.withLock { item = nil } }
}
private struct NeverGoogleHTTP: GoogleHTTPTransport {
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse { throw OAuthError.cancelled }
}
@MainActor private final class DelayedGoogleBrowser: GoogleOAuthUserAgent {
    let platform: GoogleOAuthPlatform = .desktop
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<URL, any Error>?
    private var started = false
    func prepareRedirect(configuration: GoogleCalendarConfiguration) async throws -> URL { URL(string: "http://127.0.0.1:12345/")! }
    func authorize(url: URL, redirectURI: URL) async throws -> URL {
        started = true; entered?.resume(); entered = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForStart() async { if started { return }; await withCheckedContinuation { entered = $0 } }
    func finish() { pending?.resume(throwing: OAuthError.cancelled); pending = nil }
}
@MainActor struct GoogleConnectionFlowTests {
    @Test func disconnectDuringSignInCannotReconnectOrLeaveBusyState() async throws {
        let defaultsName = "minutes-google-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: defaultsName)!
        defer { preferences.removePersistentDomain(forName: defaultsName) }
        let state = try AppState(store: MinutesStore(dbPath: ":memory:"), preferences: preferences)
        state.googleDesktopClientID = "public.apps.googleusercontent.com"
        let connection = GoogleCalendarConnection(configuration: .init(desktopClientID: state.googleDesktopClientID), credentialStore: IsolatedGoogleStore(), transport: NeverGoogleHTTP())
        let browser = DelayedGoogleBrowser()
        let task = Task { await state.connectGoogleCalendar(using: browser, connection: connection) }
        await browser.waitForStart()
        await state.disconnectGoogleCalendar()
        browser.finish()
        await task.value
        #expect(!state.googleConnected)
        #expect(!state.googleConnecting)
        #expect(!state.calendarConnected)
        #expect(state.upcomingEvents.isEmpty)
        #expect(!state.googleMessage.contains("failed"))
    }
}
