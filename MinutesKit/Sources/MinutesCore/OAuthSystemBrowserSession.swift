import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A system-owned browser sheet for native PKCE callbacks. It never handles passwords or persists callback URLs.
@MainActor public final class OAuthSystemBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?
    private var generation = 0
    private var continuation: CheckedContinuation<URL, any Error>?
    public init(anchor: ASPresentationAnchor? = nil) { self.anchor = anchor }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor }
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        guard continuation == nil else { throw OAuthError.invalidConfiguration }
        generation += 1; let attempt = generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme,
                    completionHandler: authorizationCompletion(for: attempt))
                browser.presentationContextProvider = self
                session = browser
                if !browser.start() { finish(.failure(OAuthError.presentationUnavailable)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == attempt else { return }
                self?.session?.cancel()
                self?.finish(.failure(OAuthError.cancelled))
            }
        }
    }
    // Safari may invoke this block on an XPC queue. Explicit Sendable
    // isolation prevents Swift from inheriting MainActor from authorize's
    // continuation closure and trapping before the Task can hop to it.
    func authorizationCompletion(for attempt: Int) -> @Sendable (URL?, (any Error)?) -> Void {
        { @Sendable [weak self] callback, _ in
            Task { @MainActor in
                guard self?.generation == attempt else { return }
                if let callback { self?.finish(.success(callback)) }
                else { self?.finish(.failure(OAuthError.cancelled)) }
            }
        }
    }
    private func finish(_ result: Result<URL, any Error>) {
        let pending = continuation; continuation = nil; session = nil
        pending?.resume(with: result)
    }
}
