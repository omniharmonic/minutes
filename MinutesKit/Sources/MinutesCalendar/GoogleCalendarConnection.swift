import Foundation
import MinutesCore

public struct GoogleCalendarConfiguration: Codable, Sendable, Equatable {
    public var desktopClientID: String?
    public var iOSClientID: String?
    public var calendarIDs: [String]
    public init(desktopClientID: String? = nil, iOSClientID: String? = nil, calendarIDs: [String] = ["primary"]) {
        self.desktopClientID = desktopClientID; self.iOSClientID = iOSClientID; self.calendarIDs = calendarIDs
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desktopClientID = try c.decodeIfPresent(String.self, forKey: .desktopClientID)
        iOSClientID = try c.decodeIfPresent(String.self, forKey: .iOSClientID)
        calendarIDs = try c.decodeIfPresent([String].self, forKey: .calendarIDs) ?? ["primary"]
    }
    public static func decodePublicMetadata(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["desktopClientID", "iOSClientID", "calendarIDs"]) else { throw OAuthError.invalidConfiguration }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func clientID(for platform: GoogleOAuthPlatform) throws -> String {
        guard let value = platform == .desktop ? desktopClientID : iOSClientID,
              value.hasSuffix(".apps.googleusercontent.com"), !value.contains(where: \.isWhitespace) else { throw OAuthError.invalidConfiguration }
        return value
    }
    public var iOSCallbackScheme: String? {
        iOSClientID.map { $0.split(separator: ".").reversed().joined(separator: ".") }
    }
}
/// Desktop registration is stored separately from public build metadata and user tokens.
/// It is not a confidential client identity and never replaces PKCE/state validation.
public enum GoogleDesktopClientRegistration {
    static let service = "app.minutes.oauth.google-desktop-client"
    private struct Value: Codable { let clientID: String; let clientSecret: String }
    public static func save(clientID: String, clientSecret: String, credentials: any OAuthCredentialStore = KeychainOAuthCredentialStore()) throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains(where: \.isWhitespace),
              !clientSecret.isEmpty, clientSecret.utf8.count <= 1024, !clientSecret.contains(where: \.isWhitespace) else { throw OAuthError.invalidConfiguration }
        try credentials.write(JSONEncoder().encode(Value(clientID: clientID, clientSecret: clientSecret)), service: service, account: clientID)
    }
    static func secret(clientID: String, credentials: any OAuthCredentialStore) throws -> String? {
        guard let data = try credentials.read(service: service, account: clientID) else { return nil }
        guard let value = try? JSONDecoder().decode(Value.self, from: data), value.clientID == clientID,
              !value.clientSecret.isEmpty, value.clientSecret.utf8.count <= 1024,
              !value.clientSecret.contains(where: \.isWhitespace) else { throw OAuthError.invalidConfiguration }
        return value.clientSecret
    }
}
public enum GoogleOAuthPlatform: Sendable { case desktop, iOS }
@MainActor public protocol GoogleOAuthUserAgent: AnyObject, Sendable {
    var platform: GoogleOAuthPlatform { get }
    func prepareRedirect(configuration: GoogleCalendarConfiguration) async throws -> URL
    func authorize(url: URL, redirectURI: URL) async throws -> URL
}
public struct GoogleHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol GoogleHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> GoogleHTTPResponse }
public final class GoogleURLSessionTransport: NSObject, GoogleHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    public override init() { session = URLSession(configuration: .ephemeral, delegate: RedirectBlocker(), delegateQueue: nil); super.init() }
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        return GoogleHTTPResponse(status: http.statusCode, data: data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct GoogleCalendarConnectionStatus: Sendable {
    public let connected: Bool
    public let grantedScopes: [String]
    public let expiresAt: Date?
}
public struct GoogleCalendarDescriptor: Codable, Sendable, Identifiable {
    public let id: String
    public let summary: String?
    public let primary: Bool?
    public let accessRole: String?
}
private struct GoogleStoredTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scopes: [String]
}
private struct GoogleTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let token_type: String
    let scope: String?
}

public actor GoogleCalendarConnection {
    public static let readOnlyScopes = ["https://www.googleapis.com/auth/calendar.events.readonly", "https://www.googleapis.com/auth/calendar.calendarlist.readonly"]
    private let configuration: GoogleCalendarConfiguration
    private let credentials: any OAuthCredentialStore
    private let transport: any GoogleHTTPTransport
    private let service = "app.minutes.oauth.google-calendar"
    private var activeClientID: String?
    private var generation = 0
    private var refresh: Task<GoogleStoredTokens, Error>?

    public init(configuration: GoogleCalendarConfiguration, credentialStore: any OAuthCredentialStore = KeychainOAuthCredentialStore(), transport: any GoogleHTTPTransport = GoogleURLSessionTransport()) {
        self.configuration = configuration; self.credentials = credentialStore; self.transport = transport
        #if os(iOS)
        self.activeClientID = configuration.iOSClientID
        #else
        self.activeClientID = configuration.desktopClientID
        #endif
    }
    public func status(allowInteraction: Bool = true) throws -> GoogleCalendarConnectionStatus {
        let tokens = try stored(allowInteraction: allowInteraction)
        return GoogleCalendarConnectionStatus(connected: tokens != nil, grantedScopes: tokens?.scopes ?? [], expiresAt: tokens?.expiresAt)
    }
    private func stored(allowInteraction: Bool = true) throws -> GoogleStoredTokens? {
        guard let client = activeClientID else { return nil }
        let saved = try allowInteraction ? credentials.read(service: service, account: client) : credentials.readWithoutInteraction(service: service, account: client)
        guard let data = saved else { return nil }
        guard let value = try? JSONDecoder().decode(GoogleStoredTokens.self, from: data) else { throw OAuthError.signInRequired }
        guard Set(Self.readOnlyScopes).isSubset(of: Set(value.scopes)) else { throw OAuthError.missingScopes }
        return value
    }
    public func authorizationURL(for attempt: OAuthPKCEAttempt) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [URLQueryItem(name: "client_id", value: attempt.clientID), .init(name: "redirect_uri", value: attempt.redirectURI.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: attempt.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: attempt.challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: attempt.state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account")]
        return parts.url!
    }
    public func connect(using agent: any GoogleOAuthUserAgent) async throws {
        try Task.checkCancellation()
        generation += 1
        refresh?.cancel(); refresh = nil
        let current = generation
        let platform = await agent.platform
        let client = try configuration.clientID(for: platform)
        let redirect = try await agent.prepareRedirect(configuration: configuration)
        let attempt = try OAuthPKCEAttempt(clientID: client, redirectURI: redirect, scopes: Self.readOnlyScopes)
        let callback = try await agent.authorize(url: authorizationURL(for: attempt), redirectURI: redirect)
        try Task.checkCancellation()
        let code = try attempt.authorizationCode(from: callback)
        let tokens = try await requestTokens(["client_id": client, "redirect_uri": redirect.absoluteString, "code": code,
            "code_verifier": attempt.verifier, "grant_type": "authorization_code"], previousRefresh: nil)
        try Task.checkCancellation()
        guard current == generation else { throw OAuthError.cancelled }
        generation += 1 // Invalidate reads/refreshes begun while the browser was open.
        refresh?.cancel(); refresh = nil
        try credentials.write(JSONEncoder().encode(tokens), service: service, account: client)
        activeClientID = client
    }
    private func requestTokens(_ fields: [String: String], previousRefresh: String?) async throws -> GoogleStoredTokens {
        var fields = fields
        if let client = fields["client_id"], client == configuration.desktopClientID,
           client != configuration.iOSClientID,
           let secret = try GoogleDesktopClientRegistration.secret(clientID: client, credentials: credentials) {
            fields["client_secret"] = secret
        }
        let response = try await transport.send(Self.formRequest(url: "https://oauth2.googleapis.com/token", fields: fields))
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String; let error_description: String? }
            if let failure = try? JSONDecoder().decode(Failure.self, from: response.data),
               failure.error == "invalid_client" || (failure.error == "invalid_request" && failure.error_description?.contains("client_secret") == true) {
                throw OAuthError.desktopRegistrationRequired
            }
            if response.status == 400 || response.status == 401 { throw OAuthError.signInRequired }
            throw OAuthError.remoteFailure(response.status)
        }
        let value = try JSONDecoder().decode(GoogleTokenResponse.self, from: response.data)
        guard !value.access_token.isEmpty, value.token_type.lowercased() == "bearer", value.expires_in > 0, value.expires_in.isFinite else { throw OAuthError.invalidResponse }
        let scopes = value.scope?.split(separator: " ").map(String.init) ?? Self.readOnlyScopes
        guard Set(Self.readOnlyScopes).isSubset(of: Set(scopes)) else { throw OAuthError.missingScopes }
        return GoogleStoredTokens(accessToken: value.access_token, refreshToken: value.refresh_token ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(value.expires_in), scopes: scopes)
    }
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let previous = try stored(), let client = activeClientID else { throw OAuthError.signInRequired }
        if !forceRefresh && previous.expiresAt.timeIntervalSinceNow > 60 { return previous.accessToken }
        let current = generation
        if refresh == nil {
            guard let token = previous.refreshToken else { throw OAuthError.signInRequired }
            refresh = Task { try await self.requestTokens(["client_id": client, "refresh_token": token, "grant_type": "refresh_token"], previousRefresh: token) }
        }
        do {
            let tokens = try await refresh!.value
            guard current == generation else { throw OAuthError.cancelled }
            try credentials.write(JSONEncoder().encode(tokens), service: service, account: client)
            refresh = nil
            return tokens.accessToken
        } catch {
            if current == generation {
                refresh = nil
                if case OAuthError.signInRequired = error { try credentials.delete(service: service, account: client) }
            }
            throw error
        }
    }
    public func disconnect(revoke: Bool = true) async throws {
        generation += 1
        refresh?.cancel(); refresh = nil
        let tokens = try? stored()
        if let client = activeClientID { try credentials.delete(service: service, account: client) }
        if revoke, let token = tokens?.refreshToken ?? tokens?.accessToken {
            let result = try await transport.send(Self.formRequest(url: "https://oauth2.googleapis.com/revoke", fields: ["token": token]))
            guard result.status == 200 || result.status == 400 else { throw OAuthError.remoteFailure(result.status) }
        }
    }
    private static func formRequest(url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }
    private func get(_ url: URL) async throws -> Data {
        let current = generation
        for attempt in 0...1 {
            let token = try await accessToken(forceRefresh: attempt == 1)
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let response = try await transport.send(request)
            guard current == generation else { throw OAuthError.cancelled }
            if response.status == 401 && attempt == 0 { continue }
            guard response.status == 200 else { throw OAuthError.remoteFailure(response.status) }
            return response.data
        }
        throw OAuthError.signInRequired
    }
    public func calendars() async throws -> [GoogleCalendarDescriptor] {
        let current = generation
        struct Page: Decodable { let items: [GoogleCalendarDescriptor]?; let nextPageToken: String? }
        var result: [GoogleCalendarDescriptor] = [], page: String?, visited: Set<String> = []
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            url.queryItems = [.init(name: "maxResults", value: "250"), .init(name: "minAccessRole", value: "reader")]
            if let page { url.queryItems?.append(.init(name: "pageToken", value: page)) }
            let response = try JSONDecoder().decode(Page.self, from: await get(url.url!))
            result += response.items ?? []; page = response.nextPageToken
            if let page { guard visited.insert(page).inserted, visited.count < 500 else { throw OAuthError.invalidResponse } }
        } while page != nil
        guard current == generation else { throw OAuthError.cancelled }
        return result
    }
    public func events(in interval: DateInterval, calendarIDs: [String]? = nil) async throws -> [CalendarMeetingEvent] {
        guard interval.duration > 0, interval.duration <= 32 * 86400 else { throw CalendarAccessError.invalidInterval }
        let current = generation
        let formatter = ISO8601DateFormatter()
        var result: [CalendarMeetingEvent] = []
        for calendar in calendarIDs ?? configuration.calendarIDs {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard !calendar.isEmpty, let segment = calendar.addingPercentEncoding(withAllowedCharacters: allowed) else { throw OAuthError.invalidConfiguration }
            var page: String?, visited: Set<String> = []
            repeat {
                var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(segment)/events")!
                url.queryItems = [.init(name: "timeMin", value: formatter.string(from: interval.start)), .init(name: "timeMax", value: formatter.string(from: interval.end)),
                    .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "showDeleted", value: "false"), .init(name: "maxResults", value: "250")]
                if let page { url.queryItems?.append(.init(name: "pageToken", value: page)) }
                let response = try JSONDecoder().decode(GoogleEventsPage.self, from: await get(url.url!))
                result += response.items.compactMap { $0.snapshot(calendarID: calendar) }; page = response.nextPageToken
                if let page { guard visited.insert(page).inserted, visited.count < 500 else { throw OAuthError.invalidResponse } }
            } while page != nil
        }
        guard current == generation else { throw OAuthError.cancelled }
        var seen: Set<String> = []
        return CalendarMeetingEvent.scoped(result, interval: interval).filter { seen.insert($0.id).inserted }
    }
}
