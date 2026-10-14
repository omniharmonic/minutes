import Foundation
import MinutesCore

public struct DiarizationConfig: Sendable, Codable {
    public var pauseThreshold: Double // default 1.8 seconds, range 0.5 - 3.5
    public var aggressiveness: Double // range 0.0 - 1.0
    public var minSpeechDuration: Double // default 0.3 seconds
    
    public init(
        pauseThreshold: Double = 1.8,
        aggressiveness: Double = 0.5,
        minSpeechDuration: Double = 0.3
    ) {
        self.pauseThreshold = pauseThreshold
        self.aggressiveness = aggressiveness
        self.minSpeechDuration = minSpeechDuration
    }
}

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
        speakerNames: [String: String] = [:], // speakerId -> display name
        config: DiarizationConfig = DiarizationConfig()
    ) -> [Utterance] {
        if words.isEmpty {
            return []
        }
        
        // Filter out segments shorter than minSpeechDuration (noise rejection)
        let validSegments = segments.filter { ($0.end - $0.start) >= config.minSpeechDuration }
        let activeSegments = validSegments
        
        // Filter out low confidence non-speech noise words based on aggressiveness
        let noiseConfidenceFloor = config.aggressiveness * 0.25
        let speechWords = words.filter { $0.confidence >= noiseConfidenceFloor }
        
        if speechWords.isEmpty {
            return []
        }
        
        var attributedWords: [(word: ASRWord, speakerId: String)] = []
        var lastSpeakerId = activeSegments.first?.speakerId ?? "Speaker 1"
        
        for w in speechWords {
            // Find segment with maximum overlap
            var bestSpeaker = lastSpeakerId
            var maxOverlap = 0.0
            
            for seg in activeSegments {
                let overlapStart = max(w.start, seg.start)
                let overlapEnd = min(w.end, seg.end)
                let overlap = max(0.0, overlapEnd - overlapStart)
                if overlap > maxOverlap {
                    maxOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
            }
            
            // Require minimal overlap if aggressiveness is elevated, else maintain speaker
            let minOverlapRequired = 0.02 * config.aggressiveness
            if maxOverlap > minOverlapRequired {
                lastSpeakerId = bestSpeaker
                attributedWords.append((word: w, speakerId: bestSpeaker))
            } else {
                attributedWords.append((word: w, speakerId: lastSpeakerId))
            }
        }
        
        // Group consecutive words into utterances
        var utterances: [Utterance] = []
        var currentSpeaker = ""
        var currentClusterId = ""
        var currentWords: [WordTiming] = []
        var utteranceStart = 0.0
        var lastEnd = 0.0
        var utteranceId = 1
        
        // Effective pause threshold dynamically adjusted by pauseThreshold setting
        let effectivePauseThreshold = max(0.4, config.pauseThreshold)
        
        for item in attributedWords {
            let spk = item.speakerId
            let w = item.word
            let pause = w.start - lastEnd
            
            // Check if we need to start a new utterance
            let speakerChanged = spk != currentSpeaker && !currentSpeaker.isEmpty
            let longPause = pause > effectivePauseThreshold && !currentWords.isEmpty
            
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
