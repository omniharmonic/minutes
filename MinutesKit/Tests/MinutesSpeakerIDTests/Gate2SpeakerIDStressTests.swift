import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeakerID

@Suite("Gate 2 SpeakerID Adversarial Stress Tests")
struct Gate2SpeakerIDStressTests {
    
    @Test("Stress Test 3: SpeakerMatcher attendee bonus single-counting boundary matrix")
    func testSpeakerMatcherBoundaryMatrix() {
        let autoThresh = 0.68
        let suggThresh = 0.52
        let bonus = 0.08
        let matcher = SpeakerMatcher(autoThreshold: autoThresh, suggestThreshold: suggThresh, attendeeBonus: bonus, requiredModel: nil, allowAutomaticAssignment: true, minimumMargin: 0)
        
        let pAlice = Person(id: "p_alice", displayName: "Alice Attendee")
        let pBob = Person(id: "p_bob", displayName: "Bob NonAttendee")
        
        // Voiceprints pointing along orthogonal unit vectors
        let vpAlice = Voiceprint(personId: pAlice.id, dim: 2, vector: [1.0, 0.0])
        let vpBob = Voiceprint(personId: pBob.id, dim: 2, vector: [0.0, 1.0])
        
        // Constructs a normalized unit vector with exact cosine similarity against [1.0, 0.0]
        func makeClusterForAlice(id: String, sim: Double) -> SpeakerCluster {
            let x = Float(sim)
            let y = Float(sqrt(max(0.0, 1.0 - sim * sim)))
            return SpeakerCluster(
                id: id,
                meetingId: "m_test",
                trackId: "t1",
                label: "Cluster_\(id)",
                centroid: [x, y]
            )
        }
        
        // Constructs a normalized unit vector with exact cosine similarity against [0.0, 1.0]
        func makeClusterForBob(id: String, sim: Double) -> SpeakerCluster {
            let x = Float(sqrt(max(0.0, 1.0 - sim * sim)))
            let y = Float(sim)
            return SpeakerCluster(
                id: id,
                meetingId: "m_test",
                trackId: "t1",
                label: "Cluster_\(id)",
                centroid: [x, y]
            )
        }
        
        // --- CASE 1: Vulnerability baseline: 0.53 raw sim with Alice (Attendee) ---
        // 0.53 + 0.08 = 0.61.
        // With Bug 3 fix: 0.61 is compared to autoThreshold (0.68), which is < 0.68.
        // If Bug 3 were present, thresh would be 0.68 - 0.08 = 0.60, causing false auto-match!
        let c53 = makeClusterForAlice(id: "c_053", sim: 0.53)
        let matches53 = matcher.match(
            clusters: [c53],
            people: [pAlice],
            voiceprints: [vpAlice],
            attendeePersonIds: [pAlice.id]
        )
        let m53 = matches53.first(where: { $0.clusterId == "c_053" })
        #expect(m53 != nil)
        #expect(m53?.assignment == "suggested", "CRITICAL BUG: Raw 0.53 + 0.08 bonus was double-counted into auto!")
        #expect(m53?.assignment != "auto")
        
        // --- CASE 2: High similarity near auto boundary (0.59 raw sim + 0.08 = 0.67 < 0.68) ---
        let c59 = makeClusterForAlice(id: "c_059", sim: 0.59)
        let matches59 = matcher.match(
            clusters: [c59],
            people: [pAlice],
            voiceprints: [vpAlice],
            attendeePersonIds: [pAlice.id]
        )
        let m59 = matches59.first(where: { $0.clusterId == "c_059" })
        #expect(m59?.assignment == "suggested")
        
        // --- CASE 3: Clear auto match (0.62 raw sim + 0.08 = 0.70 >= 0.68) ---
        let c62 = makeClusterForAlice(id: "c_062", sim: 0.62)
        let matches62 = matcher.match(
            clusters: [c62],
            people: [pAlice],
            voiceprints: [vpAlice],
            attendeePersonIds: [pAlice.id]
        )
        let m62 = matches62.first(where: { $0.clusterId == "c_062" })
        #expect(m62?.assignment == "auto")
        
        // --- CASE 4: Near suggestion boundary (0.43 raw sim + 0.08 = 0.51 < 0.52 -> unassigned) ---
        let c43 = makeClusterForAlice(id: "c_043", sim: 0.43)
        let matches43 = matcher.match(
            clusters: [c43],
            people: [pAlice],
            voiceprints: [vpAlice],
            attendeePersonIds: [pAlice.id]
        )
        let m43 = matches43.first(where: { $0.clusterId == "c_043" })
        #expect(m43?.assignment == "unassigned")
        
        // --- CASE 5: Just above suggestion boundary (0.45 raw sim + 0.08 = 0.53 >= 0.52 -> suggested) ---
        let c45 = makeClusterForAlice(id: "c_045", sim: 0.45)
        let matches45 = matcher.match(
            clusters: [c45],
            people: [pAlice],
            voiceprints: [vpAlice],
            attendeePersonIds: [pAlice.id]
        )
        let m45 = matches45.first(where: { $0.clusterId == "c_045" })
        #expect(m45?.assignment == "suggested")
        
        // --- CASE 6: Non-Attendee comparison (Bob is NOT in attendeePersonIds) ---
        // Bob raw sim = 0.61 -> score = 0.61 < 0.68 -> suggested (NOT auto)
        let cBob61 = makeClusterForBob(id: "c_bob61", sim: 0.61)
        let matchesBob61 = matcher.match(
            clusters: [cBob61],
            people: [pBob],
            voiceprints: [vpBob],
            attendeePersonIds: [] // No attendees
        )
        let mBob61 = matchesBob61.first(where: { $0.clusterId == "c_bob61" })
        #expect(mBob61?.assignment == "suggested")
        
        // Bob raw sim = 0.70 -> score = 0.70 >= 0.68 -> auto
        let cBob70 = makeClusterForBob(id: "c_bob70", sim: 0.70)
        let matchesBob70 = matcher.match(
            clusters: [cBob70],
            people: [pBob],
            voiceprints: [vpBob],
            attendeePersonIds: []
        )
        let mBob70 = matchesBob70.first(where: { $0.clusterId == "c_bob70" })
        #expect(mBob70?.assignment == "auto")
    }
    
    @Test("Stress Test 3b: Greedy matching arbitration between attendee with bonus and non-attendee")
    func testGreedyMatchingArbitration() {
        let pAlice = Person(id: "p_alice", displayName: "Alice (Attendee)")
        let pBob = Person(id: "p_bob", displayName: "Bob (Non-Attendee)")
        
        // Alice voiceprint at [1.0, 0.0], Bob at [0.0, 1.0]
        let vpAlice = Voiceprint(personId: pAlice.id, dim: 2, vector: [1.0, 0.0])
        let vpBob = Voiceprint(personId: pBob.id, dim: 2, vector: [0.0, 1.0])
        
        // Cluster 1 has raw similarity 0.50 with Alice and 0.54 with Bob.
        // Construct unit vector: x = 0.50 (with Alice), y = 0.54 (with Bob)
        // Wait, to be a valid unit vector: x^2 + y^2 + z^2 = 1.0
        // Let dim = 3:
        // x = 0.50 (Alice dot product)
        // y = 0.54 (Bob dot product)
        // z = sqrt(1.0 - 0.50^2 - 0.54^2) = sqrt(1.0 - 0.25 - 0.2916) = sqrt(0.4584) = 0.67705
        let z = Float(sqrt(1.0 - 0.50 * 0.50 - 0.54 * 0.54))
        let cluster1 = SpeakerCluster(
            id: "c1",
            meetingId: "m",
            trackId: "t",
            label: "Spk 1",
            centroid: [0.50, 0.54, z]
        )
        
        let vpAlice3 = Voiceprint(personId: pAlice.id, dim: 3, vector: [1.0, 0.0, 0.0])
        let vpBob3 = Voiceprint(personId: pBob.id, dim: 3, vector: [0.0, 1.0, 0.0])
        
        // Raw similarities:
        // Alice: 0.50
        // Bob: 0.54
        // Alice is Attendee (+0.08 bonus):
        // Alice score = 0.50 + 0.08 = 0.58
        // Bob score = 0.54 (non-attendee)
        // Because 0.58 > 0.54, Alice wins the greedy match for Cluster 1!
        // Both 0.58 and 0.54 are < 0.68 (autoThresh) and >= 0.52 (suggThresh), so assignment is "suggested".
        let matcher = SpeakerMatcher(autoThreshold: 0.68, suggestThreshold: 0.52, attendeeBonus: 0.08, requiredModel: nil, allowAutomaticAssignment: true, minimumMargin: 0)
        let matches = matcher.match(
            clusters: [cluster1],
            people: [pAlice, pBob],
            voiceprints: [vpAlice3, vpBob3],
            attendeePersonIds: [pAlice.id]
        )
        
        let m1 = matches.first(where: { $0.clusterId == "c1" })
        #expect(m1?.personId == pAlice.id)
        #expect(m1?.assignment == "suggested")
        #expect(m1?.confidence ?? 0.0 > 0.57)
    }
}
