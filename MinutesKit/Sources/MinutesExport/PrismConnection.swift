import Foundation
import CryptoKit
import MinutesCore

public enum PrismConnectionError: Error, LocalizedError, Sendable {
    case invalidOrigin, unsupportedServer, destinationNotAllowed, notConnected, invalidResponse, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "Use a secure Prism origin without a path, query or embedded credentials."
        case .unsupportedServer: return "This server has not verified the restricted Minutes integration contract. Minutes client registration, vault grants and integration endpoints must be enabled on the server before connecting."
        case .destinationNotAllowed: return "This vault is not allowed by the current Minutes integration grant."
        case .notConnected: return "Connect Prism and verify its restricted Minutes capabilities first."
        case .invalidResponse: return "Prism returned an invalid integration response."
        case .http(let status): return "Prism request failed (HTTP \(status))."
        }
    }
}

public struct PrismMinutesVault: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
}
/// Proposed v1 Minutes capability contract. Older generic owner tokens never satisfy this contract.
public struct PrismMinutesCapabilities: Codable, Sendable, Equatable {
    public let integration: String
    public let clientId: String
    public let restricted: Bool
    public let schemaVersions: [Int]
    public let operations: [String]
    public let vaults: [PrismMinutesVault]
    public static func decodeValidated(_ data: Data) throws -> Self {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.integration == "minutes", value.clientId == "minutes-native", value.restricted,
              value.schemaVersions.contains(1), value.operations.contains("meetings:write"), value.operations.contains("imports:read"),
              !value.vaults.isEmpty, value.vaults.count <= 100, Set(value.vaults.map(\.id)).count == value.vaults.count,
              value.vaults.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && !$0.id.contains(where: \.isNewline) }) else { throw PrismConnectionError.unsupportedServer }
        return value
    }
}

@MainActor public protocol PrismBrowserAuthorizing: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}
extension OAuthSystemBrowserSession: PrismBrowserAuthorizing {}

public struct PrismConnectionStatus: Sendable {
    public let hasCredential: Bool
    public let capabilities: PrismMinutesCapabilities?
    public var verified: Bool { hasCredential && capabilities != nil }
}

public actor PrismConnection: PrismClientProtocol {
    public nonisolated let origin: URL
    private let store: MinutesStore
    private let credentials: any OAuthCredentialStore
    private let session: URLSession
    private let service = "app.minutes.oauth.prism-integration"
    private var generation = 0
    private var capabilities: PrismMinutesCapabilities?
    private var verifiedGrant: String?

    public init(origin: URL, store: MinutesStore, credentialStore: any OAuthCredentialStore = KeychainOAuthCredentialStore(), session: URLSession? = nil) throws {
        do { try ExportHTTPTransport.validateOrigin(origin) } catch { throw PrismConnectionError.invalidOrigin }
        guard origin.path.isEmpty || origin.path == "/", var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { throw PrismConnectionError.invalidOrigin }
        parts.path = ""; parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let canonical = parts.url else { throw PrismConnectionError.invalidOrigin }
        self.origin = canonical; self.store = store; self.credentials = credentialStore
        self.session = session ?? ExportHTTPTransport.makeSession()
    }
    public func status(allowInteraction: Bool = true) throws -> PrismConnectionStatus {
        let current = try token(allowInteraction: allowInteraction)
        return PrismConnectionStatus(hasCredential: current != nil, capabilities: current.map(Self.fingerprint) == verifiedGrant ? capabilities : nil)
    }
    private func token(allowInteraction: Bool = true) throws -> String? {
        let saved = try allowInteraction
            ? credentials.read(service: service, account: origin.absoluteString)
            : credentials.readWithoutInteraction(service: service, account: origin.absoluteString)
        guard let data = saved else { return nil }
        guard let value = String(data: data, encoding: .utf8), Self.validToken(value) else { throw OAuthError.signInRequired }
        return value
    }
    private static func validToken(_ token: String) -> Bool {
        token.hasPrefix("pd_") && (20...256).contains(token.utf8.count) && token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }
    private func endpoint(_ path: String) -> URL { URL(string: path, relativeTo: origin)!.absoluteURL }
    private func request(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrismConnectionError.invalidResponse }
        return (http.statusCode, data)
    }
    private func form(_ path: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint(path)); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.keys.sorted().map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        return request
    }
    public func connect(using browser: any PrismBrowserAuthorizing, label: String = "Minutes") async throws {
        try Task.checkCancellation()
        generation += 1; let current = generation; capabilities = nil; verifiedGrant = nil
        let attempt = try OAuthPKCEAttempt(clientID: "minutes-native", redirectURI: URL(string: "minutes://auth/callback")!, scopes: [])
        var authorize = URLComponents(url: endpoint("/auth/device/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [.init(name: "response_type", value: "code"), .init(name: "client_id", value: attempt.clientID),
            .init(name: "redirect_uri", value: attempt.redirectURI.absoluteString), .init(name: "code_challenge", value: attempt.challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: attempt.state),
            .init(name: "label", value: String(label.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init).prefix(80)))]
        let callback = try await browser.authorize(url: authorize.url!, callbackScheme: "minutes")
        try Task.checkCancellation()
        let code = try attempt.authorizationCode(from: callback)
        let (status, body) = try await request(form("/auth/device/token", fields: ["grant_type": "authorization_code", "client_id": attempt.clientID,
            "code": code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString]))
        guard (200..<300).contains(status) else { throw PrismConnectionError.http(status) }
        struct TokenResponse: Decodable { let access_token: String; let token_type: String }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: body), response.token_type.lowercased() == "bearer", Self.validToken(response.access_token) else { throw PrismConnectionError.invalidResponse }
        do {
            let verified = try await fetchCapabilities(token: response.access_token)
            try Task.checkCancellation()
            guard current == generation else { throw OAuthError.cancelled }
            generation += 1
            try credentials.write(Data(response.access_token.utf8), service: service, account: origin.absoluteString)
            capabilities = verified; verifiedGrant = Self.fingerprint(response.access_token)
        } catch {
            // A newly minted but unverified device is never saved as a working connection.
            _ = try? await request(form("/auth/device/revoke", fields: ["token": response.access_token]))
            throw error
        }
    }
    private func fetchCapabilities(token: String) async throws -> PrismMinutesCapabilities {
        var req = URLRequest(url: endpoint("/api/integrations/minutes/capabilities")); req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, data) = try await request(req)
        if status == 404 || status == 501 { throw PrismConnectionError.unsupportedServer }
        if status == 401 { throw OAuthError.signInRequired }
        guard status == 200 else { throw PrismConnectionError.http(status) }
        return try PrismMinutesCapabilities.decodeValidated(data)
    }
    @discardableResult public func verifyCapabilities() async throws -> PrismMinutesCapabilities {
        let current = generation
        guard let token = try token() else { throw PrismConnectionError.notConnected }
        do {
            let value = try await fetchCapabilities(token: token)
            guard current == generation else { throw OAuthError.cancelled }
            capabilities = value; verifiedGrant = Self.fingerprint(token); return value
        } catch {
            if current == generation {
                capabilities = nil
                if case OAuthError.signInRequired = error { try credentials.delete(service: service, account: origin.absoluteString) }
            }
            throw error
        }
    }
    /// Local credentials are removed before network revocation; an error means remote revocation is unconfirmed.
    public func disconnect(revoke: Bool = true) async throws {
        generation += 1; capabilities = nil; verifiedGrant = nil
        let old = try? token()
        try credentials.delete(service: service, account: origin.absoluteString)
        if revoke, let old {
            let (status, _) = try await request(form("/auth/device/revoke", fields: ["token": old]))
            guard (200..<300).contains(status) else { throw PrismConnectionError.http(status) }
        }
    }
    public func outboxItems(includeSynced: Bool = false) -> [OutboxItem] {
        store.listOutboxItems().filter { $0.destinationOrigin == origin.absoluteString && (includeSynced || $0.status != .synced) }
    }
    public func enqueue(bundle: MeetingExportBundle, destinationVault: String, sourceRevision: Int = 1) throws -> OutboxItem {
        try requireVault(destinationVault)
        guard sourceRevision == 1 else { throw PrismError.invalidPayload("Use enqueueNextRevision to advance a committed delivery") }
        return try manager().enqueueNextRevision(bundle: bundle, destinationVault: destinationVault)
    }
    public func enqueueNextRevision(bundle: MeetingExportBundle, destinationVault: String, resolvingConflictAt serverRevision: Int? = nil) throws -> OutboxItem {
        try requireVault(destinationVault)
        return try manager().enqueueNextRevision(bundle: bundle, destinationVault: destinationVault, resolvingConflictAt: serverRevision)
    }
    private static func fingerprint(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private struct GrantBoundClient: PrismClientProtocol {
        let connection: PrismConnection
        let fingerprint: String
        func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
            try await connection.uploadBound(payload: payload, destinationVault: destinationVault, idempotencyKey: idempotencyKey, baseRevision: baseRevision, expectedGrant: fingerprint)
        }
    }
    @discardableResult public func syncPending() async throws -> [OutboxItem] {
        try await verifyCapabilities()
        return try await manager().processPending()
    }
    public func retryItem(id: String) async throws -> OutboxItem {
        try await verifyCapabilities()
        return try await manager().retryItem(id: id)
    }
    public func cancelItem(id: String) throws {
        guard store.getOutboxItem(id: id)?.destinationOrigin == origin.absoluteString else { throw PrismConnectionError.destinationNotAllowed }
        try OutboxManager(store: store, client: self).cancelItem(id: id)
    }
    private func manager() throws -> OutboxManager {
        guard let token = try token() else { throw PrismConnectionError.notConnected }
        let grant = Self.fingerprint(token)
        guard verifiedGrant == grant else { capabilities = nil; verifiedGrant = nil; throw PrismConnectionError.notConnected }
        return OutboxManager(store: store, client: GrantBoundClient(connection: self, fingerprint: grant), destinationOrigin: origin.absoluteString, grantFingerprint: grant)
    }
    private func requireVault(_ id: String) throws {
        guard let capabilities else { throw PrismConnectionError.notConnected }
        guard capabilities.vaults.contains(where: { $0.id == id }) else { throw PrismConnectionError.destinationNotAllowed }
    }
    public func uploadMeeting(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?) async throws -> PrismReceipt {
        guard let token = try token() else { throw PrismError.needsSignIn("Reconnect Prism") }
        return try await uploadBound(payload: payload, destinationVault: destinationVault, idempotencyKey: idempotencyKey, baseRevision: baseRevision, expectedGrant: Self.fingerprint(token))
    }
    private func uploadBound(payload: PrismMeetingPayload, destinationVault: String, idempotencyKey: String, baseRevision: Int?, expectedGrant: String) async throws -> PrismReceipt {
        guard let capabilities else { throw PrismError.needsSignIn("Verify the Minutes integration connection") }
        guard capabilities.vaults.contains(where: { $0.id == destinationVault }) else { throw PrismError.forbidden("Destination no longer allowed by the integration grant") }
        guard let token = try token() else { throw PrismError.needsSignIn("Reconnect Prism") }
        guard Self.fingerprint(token) == expectedGrant, verifiedGrant == expectedGrant else { throw PrismError.needsSignIn("This delivery belongs to an earlier authorization. Explicitly export the original meeting again after reviewing the account and vault.") }
        let current = generation
        let client = PrismClient(baseURL: origin, session: session, tokenProvider: { token })
        do {
            let receipt = try await client.uploadMeeting(payload: payload, destinationVault: destinationVault, idempotencyKey: idempotencyKey, baseRevision: baseRevision)
            guard current == generation else { throw OAuthError.cancelled }
            return receipt
        } catch {
            if current == generation, case PrismError.needsSignIn = error {
                self.capabilities = nil
                try credentials.delete(service: service, account: origin.absoluteString)
            }
            throw error
        }
    }
}
