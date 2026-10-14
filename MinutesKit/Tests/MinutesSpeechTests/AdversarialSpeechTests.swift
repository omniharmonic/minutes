import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeech

@Suite("Adversarial Speech & Diarization Tests")
struct AdversarialSpeechTests {
    
    @Test("Overlapping speech segments attribute words by maximum segment overlap")
    func testOverlappingSpeechSegments() {
        // Speaker 1 segment: [10.0, 20.0]
        // Speaker 2 segment (overlapping): [15.0, 25.0]
        let segments = [
            TimedSpeakerSegment(speakerId: "spk_1", start: 10.0, end: 20.0),
            TimedSpeakerSegment(speakerId: "spk_2", start: 15.0, end: 25.0),
        ]
        
        let words = [
            ASRWord(word: "First", start: 10.5, end: 11.5),     // in spk_1 only
            ASRWord(word: "speaker", start: 12.0, end: 13.0),   // in spk_1 only
            ASRWord(word: "shares", start: 16.0, end: 17.0),    // in overlap [15, 20], overlap with both = 1.0, max determines
            ASRWord(word: "second", start: 21.0, end: 22.0),   // in spk_2 only
            ASRWord(word: "turn", start: 22.5, end: 23.5)       // in spk_2 only
        ]
        
        let utterances = TranscriptMerger.merge(
            meetingId: "m_overlap",
            words: words,
            segments: segments,
            speakerNames: ["spk_1": "Speaker 1", "spk_2": "Speaker 2"]
        )
        
        #expect(!utterances.isEmpty)
        // All words are preserved
        let allWords = utterances.flatMap { $0.words }.map { $0.word }
        #expect(allWords == ["First", "speaker", "shares", "second", "turn"])
        
        // First utterance belongs to Speaker 1
        #expect(utterances.first?.speakerName == "Speaker 1")
        // Last utterance belongs to Speaker 2
        #expect(utterances.last?.speakerName == "Speaker 2")
    }
    
    @Test("Background noise rejection filters segments below minSpeechDuration")
    func testNoiseRejectionAndShortSegmentGating() {
        // Segment 1 is a 0.1s pop/artifact (below default minSpeechDuration of 0.3s)
        // Segment 2 is genuine 3.0s speech
        let segments = [
            TimedSpeakerSegment(speakerId: "spk_noise", start: 1.0, end: 1.1),
            TimedSpeakerSegment(speakerId: "spk_genuine", start: 2.0, end: 5.0)
        ]
        
        let words = [
            ASRWord(word: "valid", start: 2.2, end: 2.7, confidence: 0.95),
            ASRWord(word: "speech", start: 2.8, end: 3.4, confidence: 0.92)
        ]
        
        let config = DiarizationConfig(pauseThreshold: 1.8, aggressiveness: 0.5, minSpeechDuration: 0.3)
        let utterances = TranscriptMerger.merge(
            meetingId: "m_noise",
            words: words,
            segments: segments,
            config: config
        )
        
        #expect(utterances.count == 1)
        #expect(utterances[0].speakerName == "spk_genuine")
        #expect(utterances[0].text == "valid speech")
    }
    
    @Test("Aggressiveness filters low-confidence non-speech words")
    func testAggressivenessFiltersLowConfidenceNoise() {
        let segments = [
            TimedSpeakerSegment(speakerId: "spk_1", start: 0.0, end: 10.0)
        ]
        
        let words = [
            ASRWord(word: "[cough]", start: 1.0, end: 1.3, confidence: 0.05), // non-speech noise
            ASRWord(word: "Hello", start: 2.0, end: 2.5, confidence: 0.95),
            ASRWord(word: "everyone", start: 2.6, end: 3.2, confidence: 0.90)
        ]
        
        // With aggressiveness = 0.8, noise confidence floor is 0.8 * 0.25 = 0.20
        let highAggConfig = DiarizationConfig(pauseThreshold: 1.8, aggressiveness: 0.8, minSpeechDuration: 0.3)
        let utterances = TranscriptMerger.merge(
            meetingId: "m_agg",
            words: words,
            segments: segments,
            config: highAggConfig
        )
        
        #expect(utterances.count == 1)
        #expect(utterances[0].text == "Hello everyone")
        #expect(!utterances[0].text.contains("[cough]"))
    }
    
    @Test("Diarization pause threshold dynamically controls utterance splitting")
    func testPauseThresholdSplitting() {
        let segments = [
            TimedSpeakerSegment(speakerId: "spk_1", start: 0.0, end: 10.0)
        ]
        
        // Two phrases separated by a 1.2 second pause
        let words = [
            ASRWord(word: "Phrase", start: 1.0, end: 1.5),
            ASRWord(word: "one", start: 1.6, end: 2.0),
            // Pause from 2.0 to 3.2 = 1.2 seconds
            ASRWord(word: "Phrase", start: 3.2, end: 3.6),
            ASRWord(word: "two", start: 3.7, end: 4.0)
        ]
        
        // Strict threshold (0.8s): 1.2s pause triggers split into 2 utterances
        let strictConfig = DiarizationConfig(pauseThreshold: 0.8)
        let splitUtterances = TranscriptMerger.merge(
            meetingId: "m_split",
            words: words,
            segments: segments,
            config: strictConfig
        )
        #expect(splitUtterances.count == 2)
        #expect(splitUtterances[0].text == "Phrase one")
        #expect(splitUtterances[1].text == "Phrase two")
        
        // Lenient threshold (2.5s): 1.2s pause kept in 1 utterance
        let lenientConfig = DiarizationConfig(pauseThreshold: 2.5)
        let mergedUtterances = TranscriptMerger.merge(
            meetingId: "m_merged",
            words: words,
            segments: segments,
            config: lenientConfig
        )
        #expect(mergedUtterances.count == 1)
        #expect(mergedUtterances[0].text == "Phrase one Phrase two")
    }
    
    @Test("Bug 4 Regression: All-noise segments rejected without fallback to noise segments")
    func testAllNoiseSegmentsRejectionDoesNotFallbackToNoise() {
        // Both segments are brief transient noise pops below minSpeechDuration (0.3s)
        let noiseSegments = [
            TimedSpeakerSegment(speakerId: "spk_noise_artifact_1", start: 0.05, end: 0.15), // 0.10s
            TimedSpeakerSegment(speakerId: "spk_noise_artifact_2", start: 0.40, end: 0.52)  // 0.12s
        ]
        
        let words = [
            ASRWord(word: "glitch", start: 0.06, end: 0.12, confidence: 0.9)
        ]
        
        let config = DiarizationConfig(pauseThreshold: 1.8, aggressiveness: 0.5, minSpeechDuration: 0.3)
        let utterances = TranscriptMerger.merge(
            meetingId: "m_noise_rejection",
            words: words,
            segments: noiseSegments,
            config: config
        )
        
        // CRITICAL CHECK: Noise segments must NOT be active; utterances must never be attributed to noise artifacts
        for u in utterances {
            #expect(u.clusterId != "spk_noise_artifact_1", "Fell back to noise segment spk_noise_artifact_1!")
            #expect(u.clusterId != "spk_noise_artifact_2", "Fell back to noise segment spk_noise_artifact_2!")
            #expect(u.speakerName != "spk_noise_artifact_1")
            #expect(u.speakerName != "spk_noise_artifact_2")
        }
    }
}
