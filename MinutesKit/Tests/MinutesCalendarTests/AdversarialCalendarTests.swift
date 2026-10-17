import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesCalendar
@testable import MinutesSpeakerID

@Suite("Adversarial Calendar Tests")
struct AdversarialCalendarTests {
    
    @Test("Calendar attendee count mismatch: 5 attendees on invite, 2 active speakers")
    func testAttendeeCountOverMismatch() {
        let p1 = Person(id: "p1", displayName: "Alice Smith", emails: ["alice@corp.com"])
        let p2 = Person(id: "p2", displayName: "Bob Jones", emails: ["bob@corp.com"])
        let p3 = Person(id: "p3", displayName: "Charlie Brown", emails: ["charlie@corp.com"])
        let p4 = Person(id: "p4", displayName: "Dana Scully", emails: ["dana@corp.com"])
        let p5 = Person(id: "p5", displayName: "Fox Mulder", emails: ["fox@corp.com"])
        
        let allAttendees = [p1, p2, p3, p4, p5]
        let attendeeIds: Set<String> = ["p1", "p2", "p3", "p4", "p5"]
        
        // Only 2 speakers detected in the recording
        // c1 has strong similarity with Alice (p1)
        // c2 has strong similarity with Bob (p2)
        let vAlice: [Float] = [1.0, 0.0, 0.0]
        let vBob: [Float] = [0.0, 1.0, 0.0]
        
        let vp1 = Voiceprint(personId: p1.id, dim: 3, vector: vAlice)
        let vp2 = Voiceprint(personId: p2.id, dim: 3, vector: vBob)
        
        let c1 = SpeakerCluster(id: "c1", meetingId: "m1", trackId: "t1", label: "Speaker 1", centroid: [0.98, 0.02, 0.0])
        let c2 = SpeakerCluster(id: "c2", meetingId: "m1", trackId: "t1", label: "Speaker 2", centroid: [0.01, 0.99, 0.0])
        
        let matcher = SpeakerMatcher(autoThreshold: 0.65, suggestThreshold: 0.50, attendeeBonus: 0.08, requiredModel: nil, allowAutomaticAssignment: true, minimumMargin: 0)
        let matches = matcher.match(
            clusters: [c1, c2],
            people: allAttendees,
            voiceprints: [vp1, vp2],
            attendeePersonIds: attendeeIds
        )
        
        #expect(matches.count == 2)
        let match1 = matches.first(where: { $0.clusterId == "c1" })
        let match2 = matches.first(where: { $0.clusterId == "c2" })
        
        #expect(match1?.personId == p1.id)
        #expect(match1?.personName == "Alice Smith")
        #expect(match2?.personId == p2.id)
        #expect(match2?.personName == "Bob Jones")
    }
    
    @Test("Ad-hoc meeting with zero calendar attendees handles all clusters gracefully")
    func testZeroCalendarAttendees() {
        let p1 = Person(id: "p1", displayName: "Enrolled User")
        let vp1 = Voiceprint(personId: p1.id, dim: 2, vector: [1.0, 0.0])
        
        let c1 = SpeakerCluster(id: "c1", meetingId: "m", trackId: "t", label: "Spk 1", centroid: [0.95, 0.05])
        let c2 = SpeakerCluster(id: "c2", meetingId: "m", trackId: "t", label: "Spk 2", centroid: [-0.95, 0.05])
        
        let matcher = SpeakerMatcher(requiredModel: nil, allowAutomaticAssignment: true, minimumMargin: 0)
        // No attendees
        let matches = matcher.match(
            clusters: [c1, c2],
            people: [p1],
            voiceprints: [vp1],
            attendeePersonIds: []
        )
        
        #expect(matches.count == 2)
        let m1 = matches.first(where: { $0.clusterId == "c1" })
        let m2 = matches.first(where: { $0.clusterId == "c2" })
        
        // c1 matched by voiceprint
        #expect(m1?.personId == p1.id)
        #expect(m1?.assignment == "auto")
        // c2 has no match and is unassigned
        #expect(m2?.assignment == "unassigned")
        #expect(m2?.personId == nil)
    }
    
    @Test("NameResolver handles edge cases and malformed emails")
    func testNameResolverEdgeCases() {
        #expect(NameResolver.resolveDisplayName(fromEmail: "first.m.last@company.co.uk") == "First M Last")
        #expect(NameResolver.resolveDisplayName(fromEmail: "singleword@test.io") == "Singleword")
        #expect(NameResolver.resolveDisplayName(fromEmail: "name+tag@gmail.com") == "Name")
        #expect(NameResolver.resolveDisplayName(fromEmail: "") == "Unknown")
        #expect(NameResolver.resolveDisplayName(fromEmail: "   ") == "Unknown")
        
        #expect(NameResolver.cleanEmail("  MAILTO:User.Name@Company.COM  ") == "user.name@company.com")
        #expect(NameResolver.cleanEmail("justaname") == "justaname")
    }
}
