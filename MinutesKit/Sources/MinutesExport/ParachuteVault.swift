import Foundation
import MinutesCore

public enum ParachuteVaultError: Error, LocalizedError, Sendable, Equatable {
    case invalidServer, unsupportedServer, notConnected, signInExpired, noVaultGranted, editedInVault, http(Int, String?)
    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter your Parachute server’s address, for example parachute.example.com."
        case .unsupportedServer: "This server doesn’t offer Parachute sign-in. Check the address and that the hub is up to date."
        case .notConnected: "Sign in to your Parachute vault first."
        case .signInExpired: "Your Parachute sign-in expired. Sign in again."
        case .noVaultGranted: "Sign-in finished without access to a vault. Sign in again and choose a vault."
        case .editedInVault: "This meeting’s note was edited in your vault since the last export, so Minutes left it unchanged."
        case .http(let status, let message): "Parachute request failed (HTTP \(status))\(message.map { ": \($0)" } ?? "")."
        }
    }
}

/// What the person sees about their connection; never contains tokens.
public struct ParachuteVaultStatus: Sendable, Equatable {
    public let origin: URL
    public let vault: String
    public let vaultURL: URL
}

/// A note saved in the vault, remembered so re-exports update it in place.
public struct ParachuteNoteReceipt: Codable, Sendable, Equatable {
    public let id: String
    public let updatedAt: String?
}

/// Signs in to a Parachute hub with OAuth 2.1 (discovery, dynamic client
/// registration, PKCE S256, loopback redirect) and writes meeting notes to the
/// vault chosen on the hub's consent page. Tokens live only in the Keychain.
public actor ParachuteVaultConnection {
    public nonisolated let origin: URL
    private let credentials: any OAuthCredentialStore
    private let session: URLSession
    private static let tokenService = "app.minutes.oauth.parachute"
    private static let clientService = "app.minutes.oauth.parachute-client"
    /// A stable redirect port lets one client registration serve every sign-in.
    public static let preferredLoopbackPort: UInt16 = 47_831

    struct Metadata: Decodable, Sendable {
        let issuer: String
        let authorization_endpoint: URL
        let token_endpoint: URL
        let registration_endpoint: URL?
        let revocation_endpoint: URL?
    }

    struct Credential: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        let clientID: String
        let tokenEndpoint: URL
        let revocationEndpoint: URL?
        let vault: String
        let vaultURL: URL
    }

    public init(origin: URL, credentialStore: any OAuthCredentialStore = KeychainOAuthCredentialStore(), session: URLSession? = nil) throws {
        self.origin = try Self.normalizedOrigin(origin.absoluteString)
        self.credentials = credentialStore
        self.session = session ?? ExportHTTPTransport.makeSession()
    }

    /// Accepts `host`, `https://host`, or a vault URL such as `https://host/vault/default`.
    public static func normalizedOrigin(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard var parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { throw ParachuteVaultError.invalidServer }
        parts.path = ""; parts.query = nil; parts.fragment = nil; parts.host = host.lowercased()
        if parts.scheme == "https" && parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw ParachuteVaultError.invalidServer }
        do { try ExportHTTPTransport.validateOrigin(url) } catch { throw ParachuteVaultError.invalidServer }
        return url
    }

    // MARK: Sign-in

    /// `authorize` opens the hub's sign-in page and returns the loopback callback.
    public func connect(authorize: @Sendable (URL, OAuthLoopbackReceiver, String) async throws -> URL) async throws -> ParachuteVaultStatus {
        let metadata = try await discover()
        let receiver = try OAuthLoopbackReceiver(preferredPort: Self.preferredLoopbackPort)
        defer { receiver.cancel() }
        let clientID = try await clientID(metadata: metadata, redirect: receiver.redirectURI)
        // An unnamed vault scope makes the hub ask which vault Minutes may write to.
        let attempt = try OAuthPKCEAttempt(clientID: clientID, redirectURI: receiver.redirectURI, scopes: ["vault:write"])
        var request = URLComponents(url: metadata.authorization_endpoint, resolvingAgainstBaseURL: false)!
        request.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: receiver.redirectURI.absoluteString), .init(name: "scope", value: "vault:write"),
            .init(name: "state", value: attempt.state), .init(name: "code_challenge", value: attempt.challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = request.url else { throw ParachuteVaultError.unsupportedServer }
        let callback = try await authorize(url, receiver, attempt.state)
        let code = try attempt.authorizationCode(from: callback)
        let token = try await tokenRequest(metadata.token_endpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": receiver.redirectURI.absoluteString,
            "client_id": clientID, "code_verifier": attempt.verifier,
        ])
        guard let vault = token.grantedVault else {
            await revoke(token.access_token, endpoint: metadata.revocation_endpoint, clientID: clientID)
            throw ParachuteVaultError.noVaultGranted
        }
        let credential = Credential(accessToken: token.access_token, refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(Double(token.expires_in ?? 900)), clientID: clientID,
            tokenEndpoint: metadata.token_endpoint, revocationEndpoint: metadata.revocation_endpoint,
            vault: vault, vaultURL: origin.appendingPathComponent("vault").appendingPathComponent(vault))
        try save(credential)
        return status(credential)
    }

    public func status(allowInteraction: Bool = false) throws -> ParachuteVaultStatus? {
        try load(allowInteraction: allowInteraction).map(status)
    }

    /// Confirms the saved sign-in can read the granted vault.
    public func verify() async throws -> ParachuteVaultStatus {
        let credential = try await freshCredential()
        var components = URLComponents(url: credential.vaultURL.appendingPathComponent("api/notes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "limit", value: "1")]
        _ = try await send(components.url!, method: "GET", body: nil, credential: credential)
        return status(credential)
    }

    public func disconnect() async {
        if let credential = try? load(allowInteraction: true) {
            await revoke(credential.refreshToken ?? credential.accessToken, endpoint: credential.revocationEndpoint, clientID: credential.clientID)
        }
        try? credentials.delete(service: Self.tokenService, account: origin.absoluteString)
    }

    // MARK: Notes

    /// Creates the note, or updates the one saved before. An update never
    /// overwrites edits made in the vault since `previous` was saved.
    public func saveNote(path: String, content: String, tags: [String], metadata: [String: String],
                         previous: ParachuteNoteReceipt?) async throws -> ParachuteNoteReceipt {
        let credential = try await freshCredential()
        let notes = credential.vaultURL.appendingPathComponent("api/notes")
        if let previous {
            var body: [String: Any] = ["content": content, "metadata": metadata, "path": path]
            if let stamp = previous.updatedAt { body["if_updated_at"] = stamp } else { body["force"] = true }
            let target = notes.appendingPathComponent(previous.id)
            do { return try Self.receipt(try await send(target, method: "PATCH", body: body, credential: credential)) }
            catch ParachuteVaultError.http(404, _) { /* deleted in the vault: create it again below */ }
            catch ParachuteVaultError.http(409, _) { throw ParachuteVaultError.editedInVault }
        }
        var candidate = path
        for attempt in 0..<2 {
            let body: [String: Any] = ["path": candidate, "content": content, "tags": tags, "metadata": metadata]
            do { return try Self.receipt(try await send(notes, method: "POST", body: body, credential: credential)) }
            catch ParachuteVaultError.http(409, _) where attempt == 0 {
                // Another note already uses this path; keep both.
                candidate = path + " (" + (metadata["minutes_meeting_id"].map { String($0.prefix(6)) } ?? "2") + ")"
            }
        }
        throw ParachuteVaultError.http(409, "A note already exists at \(path)")
    }

    static func receipt(_ data: Data) throws -> ParachuteNoteReceipt {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParachuteVaultError.http(200, "unreadable response") }
        let note = (object["note"] as? [String: Any]) ?? object
        guard let id = note["id"] as? String, !id.isEmpty else { throw ParachuteVaultError.http(200, "missing note id") }
        return ParachuteNoteReceipt(id: id, updatedAt: (note["updatedAt"] ?? note["updated_at"]) as? String)
    }

    // MARK: Transport

    private func discover() async throws -> Metadata {
        let url = origin.appendingPathComponent(".well-known/oauth-authorization-server")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.registration_endpoint != nil else { throw ParachuteVaultError.unsupportedServer }
        for endpoint in [metadata.authorization_endpoint, metadata.token_endpoint] {
            guard endpoint.host?.lowercased() == origin.host?.lowercased(), endpoint.scheme == origin.scheme else { throw ParachuteVaultError.unsupportedServer }
        }
        return metadata
    }

    private func clientID(metadata: Metadata, redirect: URL) async throws -> String {
        let account = origin.absoluteString + "|" + redirect.absoluteString
        if let saved = try credentials.read(service: Self.clientService, account: account), let id = String(data: saved, encoding: .utf8), !id.isEmpty { return id }
        guard let endpoint = metadata.registration_endpoint else { throw ParachuteVaultError.unsupportedServer }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Minutes", "redirect_uris": [redirect.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none", "scope": "vault:write",
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["client_id"] as? String, !id.isEmpty else { throw ParachuteVaultError.http(status, "client registration") }
        try credentials.write(Data(id.utf8), service: Self.clientService, account: account)
        return id
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let scope: String?
        let vault: String?
        /// The vault named by the hub, or the single `vault:<name>:<verb>` scope.
        var grantedVault: String? {
            if let vault, !vault.isEmpty { return vault }
            let named = Set((scope ?? "").split(separator: " ").compactMap { item -> String? in
                let parts = item.split(separator: ":")
                return parts.count == 3 && parts[0] == "vault" ? String(parts[1]) : nil
            })
            return named.count == 1 ? named.first : nil
        }
    }

    private func tokenRequest(_ endpoint: URL, _ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents(); components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw ParachuteVaultError.signInExpired }
        guard status == 200, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw ParachuteVaultError.http(status, "token") }
        return token
    }

    /// Refresh tokens rotate, so concurrent callers share one in-flight refresh.
    private var refreshing: Task<Credential, any Error>?

    private func freshCredential() async throws -> Credential {
        if let refreshing { return try await refreshing.value }
        guard let credential = try load(allowInteraction: true) else { throw ParachuteVaultError.notConnected }
        guard credential.expiresAt.timeIntervalSinceNow < 60 else { return credential }
        guard let refresh = credential.refreshToken else { throw ParachuteVaultError.signInExpired }
        let task = Task { () throws -> Credential in
            let token = try await tokenRequest(credential.tokenEndpoint, ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": credential.clientID])
            var renewed = credential
            renewed.accessToken = token.access_token
            renewed.refreshToken = token.refresh_token ?? refresh
            renewed.expiresAt = Date().addingTimeInterval(Double(token.expires_in ?? 900))
            try save(renewed)
            return renewed
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func send(_ url: URL, method: String, body: [String: Any]?, credential: Credential) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ParachuteVaultError.signInExpired }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ParachuteVaultError.http(status, message.map { String($0.prefix(200)) })
        }
        return data
    }

    private func revoke(_ token: String, endpoint: URL?, clientID: String) async {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents(); components.queryItems = [.init(name: "token", value: token), .init(name: "client_id", value: clientID)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        _ = try? await session.data(for: request)
    }

    private func load(allowInteraction: Bool) throws -> Credential? {
        let data = try allowInteraction
            ? credentials.read(service: Self.tokenService, account: origin.absoluteString)
            : credentials.readWithoutInteraction(service: Self.tokenService, account: origin.absoluteString)
        return try data.map { try JSONDecoder().decode(Credential.self, from: $0) }
    }

    private func save(_ credential: Credential) throws {
        try credentials.write(try JSONEncoder().encode(credential), service: Self.tokenService, account: origin.absoluteString)
    }

    private func status(_ credential: Credential) -> ParachuteVaultStatus {
        ParachuteVaultStatus(origin: origin, vault: credential.vault, vaultURL: credential.vaultURL)
    }
}

/// The vault note for one meeting: a readable path inside the chosen folder,
/// Markdown without front matter (the vault keeps metadata separately).
public enum ParachuteMeetingNote {
    /// Library-settings key under which the app and CLI remember a meeting's note.
    public static func receiptKey(vaultURL: URL, meetingID: String) -> String {
        "parachute-note:\(vaultURL.absoluteString):\(meetingID)"
    }

    /// Saves the bundle to the connected vault, updating `previous` when given.
    public static func save(_ bundle: MeetingExportBundle, folder: String, previous: ParachuteNoteReceipt?,
                            using connection: ParachuteVaultConnection) async throws -> ParachuteNoteReceipt {
        try await connection.saveNote(path: path(folder: folder, meeting: bundle.meeting), content: content(bundle: bundle),
                                      tags: ["meeting"], metadata: metadata(bundle: bundle), previous: previous)
    }

    public static func path(folder: String, meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmm"
        let title = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
        let name = formatter.string(from: meeting.startedAt) + " " + (title.isEmpty ? "Meeting" : String(title.prefix(120)))
        return base.isEmpty ? name : base + "/" + name
    }

    public static func content(bundle: MeetingExportBundle) -> String {
        let rendered = MarkdownAdapter.render(bundle: bundle)
        guard rendered.hasPrefix("---\n"), let end = rendered.range(of: "\n---\n", range: rendered.index(rendered.startIndex, offsetBy: 4)..<rendered.endIndex) else { return rendered }
        return String(rendered[end.upperBound...]).trimmingCharacters(in: .newlines)
    }

    public static func metadata(bundle: MeetingExportBundle) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        var values = ["source": "minutes", "minutes_meeting_id": bundle.meeting.id, "date": formatter.string(from: bundle.meeting.startedAt)]
        if !bundle.attendees.isEmpty { values["attendees"] = bundle.attendees.map(\.displayName).joined(separator: ", ") }
        return values
    }
}
