import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum OAuthError: Error, LocalizedError, Sendable {
    case invalidConfiguration, invalidCallback, stateMismatch, authorizationDenied, signInRequired
    case invalidResponse, missingScopes, cancelled, presentationUnavailable, desktopRegistrationRequired, desktopRegistrationInvalid
    case remoteFailure(Int), keychainFailure(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "OAuth public client metadata is missing or invalid. Configure the platform's public client ID; never embed a client secret."
        case .invalidCallback, .stateMismatch: return "The authorization response did not match this sign-in attempt. Start sign-in again."
        case .authorizationDenied: return "Authorization was declined."
        case .signInRequired: return "Sign in again; saved authorization is missing, expired or revoked."
        case .desktopRegistrationRequired: return "This Minutes build is missing its Google desktop registration. Install an updated build or contact Minutes support before connecting Google Calendar."
        case .desktopRegistrationInvalid: return "This Minutes build contains an invalid Google desktop registration. Install an updated build or contact Minutes support."
        case .invalidResponse: return "The service returned an invalid authorization or calendar response."
        case .missingScopes: return "The service did not grant the required authorization scope."
        case .cancelled: return "Authorization was cancelled."
        case .presentationUnavailable: return "The system browser or native sign-in presentation is unavailable on this device."
        case .remoteFailure(let code): return "Service request failed (HTTP \(code)). Retry or reconnect your account."
        case .keychainFailure(let code): return "Secure credential storage failed (\(code)). No plaintext credentials were saved."
        }
    }
}

public protocol OAuthCredentialStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func readWithoutInteraction(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public extension OAuthCredentialStore {
    func readWithoutInteraction(service: String, account: String) throws -> Data? {
        try read(service: service, account: account)
    }
}

public struct KeychainOAuthCredentialStore: OAuthCredentialStore {
    private let allowInteraction: Bool
    public init(allowInteraction: Bool = true) { self.allowInteraction = allowInteraction }
    private func query(_ service: String, _ account: String) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        if !allowInteraction { Self.disallowInteraction(in: &value) }
        return value
    }
    private static func disallowInteraction(in query: inout [String: Any]) {
        // Apple recommends an explicit LAContext for noninteractive queries.
        // Retain the legacy UI flag for compatibility; do not change keychain stores
        // or hide previously saved items by switching to the Data Protection keychain.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
    public func read(service: String, account: String) throws -> Data? {
        try read(service: service, account: account, allowInteraction: allowInteraction)
    }
    public func readWithoutInteraction(service: String, account: String) throws -> Data? {
        try read(service: service, account: account, allowInteraction: false)
    }
    private func read(service: String, account: String, allowInteraction: Bool) throws -> Data? {
        var lookup = query(service, account)
        if !allowInteraction { Self.disallowInteraction(in: &lookup) }
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw OAuthError.keychainFailure(result) }
        return data
    }
    public func write(_ data: Data, service: String, account: String) throws {
        let key = query(service, account)
        var add = key
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(add as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let updated = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw OAuthError.keychainFailure(updated) }
        } else if result != errSecSuccess { throw OAuthError.keychainFailure(result) }
    }
    public func delete(service: String, account: String) throws {
        let result = SecItemDelete(query(service, account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw OAuthError.keychainFailure(result) }
    }
}

public struct OAuthPKCEAttempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "OAuthPKCEAttempt(<redacted>)" }
    public var debugDescription: String { description }
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let verifier: String
    public let state: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public init(clientID: String, redirectURI: URL, scopes: [String], verifier: String? = nil, state: String? = nil) throws {
        self.clientID = clientID; self.redirectURI = redirectURI; self.scopes = scopes
        self.verifier = try verifier ?? Self.randomValue()
        self.state = try state ?? Self.randomValue()
        guard !clientID.isEmpty, (43...128).contains(self.verifier.utf8.count), !self.state.isEmpty,
              self.verifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else { throw OAuthError.invalidConfiguration }
    }
    public static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthError.invalidConfiguration }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func authorizationCode(from callback: URL) throws -> String {
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil, let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw OAuthError.invalidCallback }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              let responseState = items.first(where: { $0.name == "state" })?.value else { throw OAuthError.stateMismatch }
        let left = Array(state.utf8), right = Array(responseState.utf8)
        guard left.count == right.count else { throw OAuthError.stateMismatch }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        guard difference == 0 else { throw OAuthError.stateMismatch }
        if items.contains(where: { $0.name == "error" }) { throw OAuthError.authorizationDenied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw OAuthError.invalidCallback }
        return code
    }
}
