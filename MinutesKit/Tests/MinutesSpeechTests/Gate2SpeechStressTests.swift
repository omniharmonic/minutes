import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeech

@Suite("Gate 2 Speech & Diarization Adversarial Stress Tests")
struct Gate2SpeechStressTests {
    
    @Test("Stress Test 4: All-noise segments below minSpeechDuration are rejected without fallback")
    func testAllNoiseSegmentsRejectedNoFallback() {
        // 4 rapid noise pops (clicks, pops, throat clears) all < minSpeechDuration (0.35s)
        let noiseSegments = [
            TimedSpeakerSegment(speakerId: "spk_noise_click", start: 0.05, end: 0.15),
            TimedSpeakerSegment(speakerId: "spk_noise_pop", start: 0.40, end: 0.55),
            TimedSpeakerSegment(speakerId: "spk_noise_hum", start: 1.00, end: 1.25),
            TimedSpeakerSegment(speakerId: "spk_noise_rustle", start: 2.00, end: 2.20)
        ]
        
        let words = [
            ASRWord(word: "Hello", start: 0.06, end: 0.14, confidence: 0.90),
            ASRWord(word: "World", start: 0.42, end: 0.50, confidence: 0.88),
            ASRWord(word: "Testing", start: 1.05, end: 1.20, confidence: 0.92)
        ]
        
        let config = DiarizationConfig(pauseThreshold: 1.8, aggressiveness: 0.5, minSpeechDuration: 0.35)
        let utterances = TranscriptMerger.merge(
            meetingId: "m_noise_stress",
            words: words,
            segments: noiseSegments,
            config: config
        )
        
        // EMPIRICAL VERIFICATION: Noise speaker IDs must NEVER be assigned
        let noiseSpeakerIds = Set(["spk_noise_click", "spk_noise_pop", "spk_noise_hum", "spk_noise_rustle"])
        for u in utterances {
            #expect(!noiseSpeakerIds.contains(u.clusterId), "Utterance clusterId erroneously assigned to noise segment: \(u.clusterId)")
            #expect(!noiseSpeakerIds.contains(u.speakerName), "Utterance speakerName erroneously assigned to noise segment: \(u.speakerName)")
        }
    }
    
    @Test("Stress Test 5: Complex 3-speaker overlapping speech disambiguation by maximum overlap")
    func testThreeSpeakerOverlappingDisambiguation() {
        // Speaker 1: [0.0, 10.0]
        // Speaker 2: [6.0, 16.0]  (overlaps Speaker 1 between 6.0 and 10.0)
        // Speaker 3: [12.0, 22.0] (overlaps Speaker 2 between 12.0 and 16.0)
        let segments = [
            TimedSpeakerSegment(speakerId: "spk_1", start: 0.0, end: 10.0),
            TimedSpeakerSegment(speakerId: "spk_2", start: 6.0, end: 16.0),
            TimedSpeakerSegment(speakerId: "spk_3", start: 12.0, end: 22.0)
        ]
        
        let words = [
            // Word 1: in spk_1 exclusively [2.0, 4.0]
            ASRWord(word: "Intro", start: 2.0, end: 4.0),
            // Word 2: in overlap [7.0, 9.0]: overlap with spk_1 is 2.0s, overlap with spk_2 is 2.0s (tie break)
            ASRWord(word: "Contested", start: 7.0, end: 9.0),
            // Word 3: in [10.5, 11.5]: spk_1 ended at 10.0, spk_2 is active [6, 16], spk_3 not yet started -> spk_2 exclusively
            ASRWord(word: "SoloTwo", start: 10.5, end: 11.5),
            // Word 4: in [14.0, 18.0]: overlap with spk_2 is [14, 16] = 2.0s, overlap with spk_3 is [14, 18] = 4.0s -> spk_3 wins!
            ASRWord(word: "SpeakerThreeDominates", start: 14.0, end: 18.0),
            // Word 5: in [20.0, 21.0]: spk_3 exclusively
            ASRWord(word: "Outro", start: 20.0, end: 21.0)
        ]
        
        let speakerNames = ["spk_1": "Alice", "spk_2": "Bob", "spk_3": "Charlie"]
        let config = DiarizationConfig(pauseThreshold: 10.0) // keep in continuity
        
        let utterances = TranscriptMerger.merge(
            meetingId: "m_overlap_3spk",
            words: words,
            segments: segments,
            speakerNames: speakerNames,
            config: config
        )
        
        #expect(!utterances.isEmpty)
        
        // Find utterances containing specific words
        let uIntro = utterances.first(where: { $0.text.contains("Intro") })
        #expect(uIntro?.speakerName == "Alice")
        
        let uSoloTwo = utterances.first(where: { $0.text.contains("SoloTwo") })
        #expect(uSoloTwo?.speakerName == "Bob")
        
        let uThree = utterances.first(where: { $0.text.contains("SpeakerThreeDominates") })
        #expect(uThree?.speakerName == "Charlie", "Max overlap failed: Word [14, 18] overlapped spk_3 by 4.0s vs spk_2 by 2.0s, but was attributed to \(uThree?.speakerName ?? "nil")")
        
        let uOutro = utterances.first(where: { $0.text.contains("Outro") })
        #expect(uOutro?.speakerName == "Charlie")
    }
}
