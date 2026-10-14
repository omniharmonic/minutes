import Testing
import Foundation
@testable import MinutesCalendar

@Suite("MinutesCalendar Tests")
struct MinutesCalendarTests {
    @Test("NameResolver resolves names from diverse email styles")
    func testNameResolver() {
        #expect(NameResolver.resolveDisplayName(fromEmail: "ana.lopez@company.com") == "Ana Lopez")
        #expect(NameResolver.resolveDisplayName(fromEmail: "john_doe@stripe.com") == "John Doe")
        #expect(NameResolver.resolveDisplayName(fromEmail: "mailto:alex-smith@apple.com") == "Alex Smith")
        #expect(NameResolver.cleanEmail("mailto:Test@Domain.COM ") == "test@domain.com")
    }
    
    @Test("ConferenceLinkParser detects video conference URLs")
    func testConferenceLinkParser() {
        let meetText = "Join at https://meet.google.com/abc-defg-hij on time"
        let zoomText = "Zoom link: https://us02web.zoom.us/j/123456789 passcode 42"
        let teamsText = "Join Microsoft Teams: https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz"
        
        #expect(ConferenceLinkParser.parseConferenceURL(from: meetText) == "https://meet.google.com/abc-defg-hij")
        #expect(ConferenceLinkParser.parseConferenceURL(from: zoomText) == "https://us02web.zoom.us/j/123456789")
        #expect(ConferenceLinkParser.parseConferenceURL(from: teamsText)?.contains("teams.microsoft.com") == true)
        #expect(ConferenceLinkParser.parseConferenceURL(from: "No links here") == nil)
    }
}
