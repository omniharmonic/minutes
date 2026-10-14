import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeech

@Suite("MinutesSpeech Tests")
struct MinutesSpeechTests {
    @Test("TranscriptMerger assigns words to segments by overlap")
    func testTranscriptMerger() {
        let words: [ASRWord] = [
            ASRWord(word: "Hello", start: 0.0, end: 0.5),
            ASRWord(word: "world", start: 0.6, end: 1.0),
            ASRWord(word: "Yes", start: 1.2, end: 1.5),
            ASRWord(word: "indeed", start: 1.6, end: 2.0),
        ]
        
        let segments: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(speakerId: "spk_1", start: 0.0, end: 1.1),
            TimedSpeakerSegment(speakerId: "spk_2", start: 1.15, end: 2.5),
        ]
        
        let utterances = TranscriptMerger.merge(
            meetingId: "m1",
            words: words,
            segments: segments,
            speakerNames: ["spk_1": "Alice", "spk_2": "Bob"]
        )
        
        #expect(utterances.count == 2)
        #expect(utterances[0].speakerName == "Alice")
        #expect(utterances[0].text == "Hello world")
        #expect(utterances[1].speakerName == "Bob")
        #expect(utterances[1].text == "Yes indeed")
    }
}
