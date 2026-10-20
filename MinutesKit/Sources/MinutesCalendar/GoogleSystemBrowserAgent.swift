import AuthenticationServices
import Foundation
import MinutesCore
#if os(macOS)
import AppKit
import Darwin
#else
import UIKit
#endif

/// Retain this object for the duration of sign-in. Calling connect is the only action that opens a browser.
@MainActor public final class GoogleSystemBrowserAgent: NSObject, GoogleOAuthUserAgent {
    public var platform: GoogleOAuthPlatform {
        #if os(macOS)
        .desktop
        #else
        .iOS
        #endif
    }
    private let anchor: ASPresentationAnchor?
    #if os(macOS)
    private var loopback: OAuthLoopbackReceiver?
    #endif
    public init(anchor: ASPresentationAnchor? = nil) { self.anchor = anchor }
    public func prepareRedirect(configuration: GoogleCalendarConfiguration) async throws -> URL {
        #if os(macOS)
        let receiver = try OAuthLoopbackReceiver()
        loopback = receiver
        return receiver.redirectURI
        #else
        _ = try configuration.clientID(for: .iOS)
        guard let scheme = configuration.iOSCallbackScheme, let url = URL(string: scheme + ":/oauth2redirect") else { throw OAuthError.invalidConfiguration }
        return url
        #endif
    }
    public func authorize(url: URL, redirectURI: URL) async throws -> URL {
        #if os(macOS)
        guard let receiver = loopback else { throw OAuthError.invalidConfiguration }
        defer { receiver.cancel(); loopback = nil }
        // Desktop OAuth clients use a loopback redirect, as required by Google's installed-app policy.
        guard NSWorkspace.shared.open(url) else { throw OAuthError.presentationUnavailable }
        guard let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { throw OAuthError.invalidConfiguration }
        return try await withTaskCancellationHandler { try await receiver.receive(expectedState: state) } onCancel: { receiver.cancel() }
        #else
        let browser = OAuthSystemBrowserSession(anchor: anchor)
        return try await browser.authorize(url: url, callbackScheme: redirectURI.scheme!)
        #endif
    }
}


