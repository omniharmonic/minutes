import Foundation
import Testing
@testable import MinutesSpeech

struct PrivacyPreflightTests {
    @Test func absentOrBlankSpeechDescriptionFailsBeforePermissionRequest() throws {
        for description in [nil, "", "  \n"] as [String?] {
            #expect(throws: ASRError.self) { try ASRService.validateSpeechUsageDescription(description) }
        }
        try ASRService.validateSpeechUsageDescription("Transcribe meetings on this device.")
    }
}

extension PrivacyPreflightTests {
    @Test func directChildCannotRequestSpeechConsentFromHostingApp() throws {
        #expect(throws: ASRError.self) { try ASRService.validateConsentLaunch(isAppBundle: true, parentPID: 12345) }
        #expect(throws: ASRError.self) { try ASRService.validateConsentLaunch(isAppBundle: false, parentPID: 1) }
        try ASRService.validateConsentLaunch(isAppBundle: true, parentPID: 1)
    }
}
