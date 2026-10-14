import Testing
import Foundation
import MinutesCore
import MinutesSpeakerID

@Suite("Gate M2: Speaker Learning and Acoustic Centroid Verifications")
struct LearningAndPlaybackTests {
    
    @Test("ClusterManager split does NOT apply synthetic +-0.02 perturbation")
    func testSplitHasNoSyntheticPerturbation() {
        let baseVector: [Float] = (0..<256).map { i in
            return Float(sin(Double(i) * 0.1))
        }
        let normalizedBase = VectorMath.l2Normalize(baseVector)
        
        let cluster = SpeakerCluster(
            id: "c_split_test",
            meetingId: "m_test",
            trackId: "t1",
            label: "Speaker 1",
            centroid: normalizedBase,
            speechSeconds: 60.0
        )
        
        let manager = ClusterManager()
        let (c1, c2, _) = manager.split(cluster: cluster, boundaryTimestamp: 30.0, utterances: [])
        
        // Both split halves inherit the genuine normalized acoustic centroid
        #expect(c1.centroid.count == 256)
        #expect(c2.centroid.count == 256)
        
        // Centroids must be exact L2 normalized unit vectors (magnitude ~ 1.0)
        let norm1 = sqrt(c1.centroid.reduce(0.0) { $0 + $1 * $1 })
        let norm2 = sqrt(c2.centroid.reduce(0.0) { $0 + $1 * $1 })
        #expect(abs(norm1 - 1.0) < 1e-4)
        #expect(abs(norm2 - 1.0) < 1e-4)
        
        // Verify no arbitrary offset: similarity to base vector should be 1.0
        let sim1 = VectorMath.cosineSimilarity(c1.centroid, normalizedBase)
        let sim2 = VectorMath.cosineSimilarity(c2.centroid, normalizedBase)
        #expect(abs(sim1 - 1.0) < 1e-5)
        #expect(abs(sim2 - 1.0) < 1e-5)
        
        // Timestamps & durations sum correctly
        #expect(c1.speechSeconds == 30.0)
        #expect(c2.speechSeconds == 30.0)
    }
    
    @Test("Speaker enrollment learns voiceprint and matches future meetings")
    func testSpeakerEnrollmentAndMatching() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let store = try MinutesStore(dbPath: tempDir.appendingPathComponent("test.db").path)
        
        // 1. Create a person
        let person = Person(id: "p_elena", displayName: "Dr. Elena Rostova", isMe: false, emails: ["elena@institute.org"])
        try store.savePerson(person)
        
        // 2. Generate a realistic acoustic centroid (e.g. vocal formants at 256 dimensions)
        let elenaVoiceVector = VectorMath.l2Normalize((0..<256).map { i in
            return Float(sin(Double(i) * 0.25) + cos(Double(i) * 0.12))
        })
        
        // 3. User confirms speaker -> enroll voiceprint
        let voiceprint = Voiceprint(id: "vp_elena_1", personId: person.id, vector: elenaVoiceVector, speechSeconds: 45.0)
        try store.saveVoiceprint(voiceprint)
        
        let savedPrints = store.listVoiceprints()
        #expect(savedPrints.count == 1)
        #expect(savedPrints[0].personId == "p_elena")
        
        // 4. In a subsequent meeting, a new cluster appears with similar acoustic vector (+ small acoustic noise < 0.05)
        let noisyVoiceVector = VectorMath.l2Normalize((0..<256).map { i in
            let base = elenaVoiceVector[i]
            let noise = Float(sin(Double(i) * 1.5)) * 0.04
            return base + noise
        })
        
        let newCluster = SpeakerCluster(
            id: "c_new_test",
            meetingId: "m_next",
            trackId: "t1",
            label: "Speaker 1",
            centroid: noisyVoiceVector,
            speechSeconds: 20.0
        )
        
        let matcher = SpeakerMatcher()
        let matchResults = matcher.match(
            clusters: [newCluster],
            people: [person],
            voiceprints: savedPrints,
            attendeePersonIds: [person.id]
        )
        
        #expect(!matchResults.isEmpty)
        let matchResult = matchResults.first!
        #expect(matchResult.personId == "p_elena")
        #expect(matchResult.personName == "Dr. Elena Rostova")
        #expect(matchResult.assignment == "suggested" || matchResult.assignment == "auto")
        #expect(matchResult.confidence > 0.85) // High confidence match based on learned voiceprint
    }
}
