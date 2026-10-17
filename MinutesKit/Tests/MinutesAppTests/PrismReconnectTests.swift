import Foundation
import Testing
import MinutesCore
import MinutesExport
@testable import MinutesApp

private final class ReconnectCredentials: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var requiresApproval = false
    func readWithoutInteraction(service: String, account: String) throws -> Data? {
        if requiresApproval { throw OAuthError.keychainFailure(-25308) }
        return try read(service: service, account: account)
    }
    init(saved: Bool) { data = saved ? Data("pd_fixture_reconnect_1234567890".utf8) : nil }
    func read(service: String, account: String) throws -> Data? { lock.withLock { data } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { self.data = data } }
    func delete(service: String, account: String) throws { lock.withLock { data = nil } }
}
private final class ReconnectProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "restore.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"integration":"minutes","clientId":"minutes-native","restricted":true,"schemaVersions":[1],"operations":["meetings:write","imports:read"],"vaults":[{"id":"staging","name":"Minutes Staging"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class WaitingPrismBrowser: PrismBrowserAuthorizing {
    var started = false
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        started = true
        try await Task.sleep(for: .seconds(60))
        throw OAuthError.cancelled
    }
}
@MainActor struct PrismReconnectTests {
    private func fixture(saved: Bool, requiresApproval: Bool = false) throws -> (AppState, URLSession, String) {
        let name = "minutes-prism-restore-test-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        prefs.set("https://restore.invalid", forKey: "prismOrigin")
        let store = try MinutesStore(dbPath: ":memory:")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReconnectProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = ReconnectCredentials(saved: saved)
        credentials.requiresApproval = requiresApproval
        let connection = try PrismConnection(origin: URL(string: "https://restore.invalid")!, store: store, credentialStore: credentials, session: session)
        return (try AppState(store: store, preferences: prefs, prismConnection: connection), session, name)
    }
    @Test func restoresSavedGrantWithoutOpeningBrowser() async throws {
        let (state, session, name) = try fixture(saved: true)
        defer { session.invalidateAndCancel(); UserDefaults().removePersistentDomain(forName: name) }
        await state.restorePrismConnection()
        #expect(state.prismVerified)
        #expect(state.prismVaultID == "staging")
        #expect(!state.prismBusy)
    }
    @Test func missingGrantDoesNotPretendConnected() async throws {
        let (state, session, name) = try fixture(saved: false)
        defer { session.invalidateAndCancel(); UserDefaults().removePersistentDomain(forName: name) }
        await state.restorePrismConnection()
        #expect(!state.prismVerified)
        #expect(state.prismMessage.contains("Connect"))
    }
    @Test func automaticRestoreDoesNotPromptForKeychainApproval() async throws {
        let (state, session, name) = try fixture(saved: true, requiresApproval: true)
        defer { session.invalidateAndCancel(); UserDefaults().removePersistentDomain(forName: name) }
        await state.restorePrismConnection()
        #expect(!state.prismVerified)
        #expect(!state.prismBusy)
        #expect(state.prismMessage.contains("Verify"))
        // Explicit Verify remains able to request the saved credential.
        await state.verifyPrism()
        #expect(state.prismVerified)
    }
    @Test func cancelClearsBusyAndCannotReconnectLate() async throws {
        let (state, session, name) = try fixture(saved: false)
        defer { session.invalidateAndCancel(); UserDefaults().removePersistentDomain(forName: name) }
        let browser = WaitingPrismBrowser()
        let task = Task { await state.connectPrism(using: browser) }
        while !browser.started { await Task.yield() }
        state.cancelPrismAuthorization()
        #expect(!state.prismBusy)
        task.cancel()
        await task.value
        #expect(!state.prismVerified)
    }
}
