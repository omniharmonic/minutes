import AuthenticationServices
import Foundation
import Testing
@testable import MinutesCore

// Apple calls this legacy completion block on its Safari XPC queue. The box
// models that Objective-C boundary without incorrectly promising main isolation.
private struct SystemCompletion: @unchecked Sendable {
    let body: ASWebAuthenticationSession.CompletionHandler
}

@Suite struct OAuthBrowserCallbackTests {
    @MainActor @Test func safariCallbackAcceptsBackgroundDelivery() async {
        let browser = OAuthSystemBrowserSession()
        let completion = SystemCompletion(body: browser.authorizationCompletion(for: 0))
        await Task.detached {
            completion.body(URL(string: "minutes://auth/callback?code=synthetic"), nil)
        }.value
        await Task.yield()
        withExtendedLifetime(browser) {}
    }
}
