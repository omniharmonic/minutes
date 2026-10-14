import Foundation
import MinutesCore

public struct TimedSpeakerSegment: Sendable {
    public let speakerId: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]
    
    public init(speakerId: String, start: Double, end: Double, embedding: [Float] = []) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

public struct ASRWord: Sendable {
    public let word: String
    public let start: Double
    public let end: Double
    public let confidence: Double
    
    public init(word: String, start: Double, end: Double, confidence: Double = 1.0) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public enum TranscriptMerger {
    /// Merges discrete ASR words and diarization segments into speaker-attributed Utterances.
    public static func merge(
        meetingId: String,
        words: [ASRWord],
        segments: [TimedSpeakerSegment],
        speakerNames: [String: String] = [:] // speakerId -> display name
    ) -> [Utterance] {
        if words.isEmpty {
            return []
        }
        
        var attributedWords: [(word: ASRWord, speakerId: String)] = []
        var lastSpeakerId = segments.first?.speakerId ?? "Speaker 1"
        
        for w in words {
            // Find segment with maximum overlap
            var bestSpeaker = lastSpeakerId
            var maxOverlap = 0.0
            
            for seg in segments {
                let overlapStart = max(w.start, seg.start)
                let overlapEnd = min(w.end, seg.end)
                let overlap = max(0.0, overlapEnd - overlapStart)
                if overlap > maxOverlap {
                    maxOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
            }
            
            lastSpeakerId = bestSpeaker
            attributedWords.append((word: w, speakerId: bestSpeaker))
        }
        
        // Group consecutive words into utterances
        var utterances: [Utterance] = []
        var currentSpeaker = ""
        var currentClusterId = ""
        var currentWords: [WordTiming] = []
        var utteranceStart = 0.0
        var lastEnd = 0.0
        var utteranceId = 1
        
        for item in attributedWords {
            let spk = item.speakerId
            let w = item.word
            let pause = w.start - lastEnd
            
            // Check if we need to start a new utterance
            let speakerChanged = spk != currentSpeaker && !currentSpeaker.isEmpty
            let longPause = pause > 1.8 && !currentWords.isEmpty
            
            if speakerChanged || longPause {
                let text = currentWords.map { $0.word }.joined(separator: " ")
                let spkName = speakerNames[currentSpeaker] ?? currentSpeaker
                utterances.append(Utterance(
                    id: utteranceId,
                    meetingId: meetingId,
                    clusterId: currentClusterId,
                    speakerName: spkName,
                    start: utteranceStart,
                    end: lastEnd,
                    text: text,
                    words: currentWords
                ))
                utteranceId += 1
                currentWords = []
            }
            
            if currentWords.isEmpty {
                currentSpeaker = spk
                currentClusterId = spk
                utteranceStart = w.start
            }
            
            currentWords.append(WordTiming(word: w.word, start: w.start, end: w.end, confidence: w.confidence))
            lastEnd = w.end
        }
        
        if !currentWords.isEmpty {
            let text = currentWords.map { $0.word }.joined(separator: " ")
            let spkName = speakerNames[currentSpeaker] ?? currentSpeaker
            utterances.append(Utterance(
                id: utteranceId,
                meetingId: meetingId,
                clusterId: currentClusterId,
                speakerName: spkName,
                start: utteranceStart,
                end: lastEnd,
                text: text,
                words: currentWords
            ))
        }
        
        return utterances
    }
}
