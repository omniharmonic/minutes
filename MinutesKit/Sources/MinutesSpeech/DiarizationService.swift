import Foundation
import MinutesCore

public struct DiarizationResult: Sendable {
    public let segments: [TimedSpeakerSegment]
    public let clusters: [SpeakerCluster]
    public let speechDuration: Double
    public let totalDuration: Double
    
    public init(
        segments: [TimedSpeakerSegment],
        clusters: [SpeakerCluster],
        speechDuration: Double,
        totalDuration: Double
    ) {
        self.segments = segments
        self.clusters = clusters
        self.speechDuration = speechDuration
        self.totalDuration = totalDuration
    }
}

public final class DiarizationService: Sendable {
    public init() {}
    
    /// Performs Voice Activity Detection, acoustic segmentation, and speaker clustering on audio samples.
    public func diarize(
        samples: [Float],
        sampleRate: Double = 16000.0,
        meetingId: String,
        trackId: String = "track_1",
        config: DiarizationConfig = DiarizationConfig()
    ) -> DiarizationResult {
        let totalDuration = Double(samples.count) / sampleRate
        guard samples.count >= Int(sampleRate * config.minSpeechDuration) else {
            return DiarizationResult(segments: [], clusters: [], speechDuration: 0.0, totalDuration: totalDuration)
        }
        
        let frameSize = Int(sampleRate * 0.020) // 20ms frame
        guard frameSize > 0 else {
            return DiarizationResult(segments: [], clusters: [], speechDuration: 0.0, totalDuration: totalDuration)
        }
        
        let numFrames = samples.count / frameSize
        var frameEnergies = [Float](repeating: 0.0, count: numFrames)
        
        for f in 0..<numFrames {
            var sumSquare: Float = 0.0
            let start = f * frameSize
            for i in 0..<frameSize {
                let s = samples[start + i]
                sumSquare += s * s
            }
            frameEnergies[f] = sqrt(sumSquare / Float(frameSize))
        }
        
        // Compute adaptive noise floor and dynamic peak threshold
        let sortedEnergies = frameEnergies.sorted()
        let peakEnergy = sortedEnergies.last ?? 0.0
        let noiseFloorIdx = Int(Float(numFrames) * 0.10)
        let noiseFloor = sortedEnergies[max(0, min(numFrames - 1, noiseFloorIdx))]
        
        let dynamicThreshold = max(0.003, peakEnergy * Float(0.04 + 0.08 * config.aggressiveness))
        let speechThreshold: Float
        if noiseFloor < peakEnergy * 0.35 {
            speechThreshold = max(dynamicThreshold, noiseFloor * (1.2 + Float(config.aggressiveness) * 0.8))
        } else {
            speechThreshold = dynamicThreshold
        }
        
        // 1. Voice Activity Detection (VAD) frame labels
        var isSpeech = [Bool](repeating: false, count: numFrames)
        for f in 0..<numFrames {
            isSpeech[f] = frameEnergies[f] >= speechThreshold
        }
        
        // 2. Group into contiguous speech segments
        struct RawSegment {
            var startFrame: Int
            var endFrame: Int
        }
        
        var rawSegments: [RawSegment] = []
        let maxPauseFrames = Int(config.pauseThreshold / 0.020)
        let minSpeechFrames = Int(config.minSpeechDuration / 0.020)
        
        var inSegment = false
        var segStart = 0
        var pauseCount = 0
        
        for f in 0..<numFrames {
            if isSpeech[f] {
                if !inSegment {
                    inSegment = true
                    segStart = f
                }
                pauseCount = 0
            } else {
                if inSegment {
                    pauseCount += 1
                    if pauseCount >= maxPauseFrames {
                        let segEnd = f - pauseCount
                        if (segEnd - segStart) >= minSpeechFrames {
                            rawSegments.append(RawSegment(startFrame: segStart, endFrame: segEnd))
                        }
                        inSegment = false
                        pauseCount = 0
                    }
                }
            }
        }
        
        if inSegment {
            let segEnd = numFrames - pauseCount
            if (segEnd - segStart) >= minSpeechFrames {
                rawSegments.append(RawSegment(startFrame: segStart, endFrame: segEnd))
            }
        }
        
        guard !rawSegments.isEmpty else {
            return DiarizationResult(segments: [], clusters: [], speechDuration: 0.0, totalDuration: totalDuration)
        }
        
        // 3. Extract embeddings for each segment (dividing long segments into up to 2.0s windows)
        struct SegmentItem {
            let startSec: Double
            let endSec: Double
            let embedding: [Float]
        }
        
        var segmentItems: [SegmentItem] = []
        var totalSpeechDuration = 0.0
        let maxSubSegFrames = Int(2.0 / 0.020)
        
        for raw in rawSegments {
            var currentStart = raw.startFrame
            while currentStart < raw.endFrame {
                let currentEnd = min(raw.endFrame, currentStart + maxSubSegFrames)
                let sStart = Double(currentStart * frameSize) / sampleRate
                let sEnd = Double(currentEnd * frameSize) / sampleRate
                let segSampleStart = currentStart * frameSize
                let segSampleEnd = min(samples.count, currentEnd * frameSize)
                let segSamples = Array(samples[segSampleStart..<segSampleEnd])
                
                let emb = EmbeddingService.extractEmbedding(samples: segSamples, sampleRate: sampleRate)
                segmentItems.append(SegmentItem(startSec: sStart, endSec: sEnd, embedding: emb))
                totalSpeechDuration += (sEnd - sStart)
                
                currentStart = currentEnd
            }
        }
        
        // 4. Agglomerative speaker clustering based on cosine similarity
        struct ClusterState {
            var id: String
            var label: String
            var segmentIndices: [Int]
            var centroid: [Float]
            var speechSeconds: Double
        }
        
        var clusterStates: [ClusterState] = []
        let clusterSimThreshold: Float = 0.70 // minimum cosine similarity to group segments into same speaker
        
        for (idx, item) in segmentItems.enumerated() {
            var bestClusterIdx: Int? = nil
            var maxSim: Float = -1.0
            
            for (cIdx, cluster) in clusterStates.enumerated() {
                let sim = cosineSimilarity(item.embedding, cluster.centroid)
                if sim > maxSim {
                    maxSim = sim
                    bestClusterIdx = cIdx
                }
            }
            
            let segDuration = item.endSec - item.startSec
            if let bIdx = bestClusterIdx, maxSim >= clusterSimThreshold {
                // Add to existing cluster and update centroid
                clusterStates[bIdx].segmentIndices.append(idx)
                let oldWeight = Float(clusterStates[bIdx].speechSeconds)
                let newWeight = Float(segDuration)
                let totalWeight = oldWeight + newWeight
                
                var newCentroid = [Float](repeating: 0.0, count: EmbeddingService.embeddingDimension)
                for d in 0..<EmbeddingService.embeddingDimension {
                    newCentroid[d] = (clusterStates[bIdx].centroid[d] * oldWeight + item.embedding[d] * newWeight) / max(1e-6, totalWeight)
                }
                // Normalize
                let norm = sqrt(newCentroid.map { $0 * $0 }.reduce(0, +))
                if norm > 1e-9 {
                    for d in 0..<EmbeddingService.embeddingDimension {
                        newCentroid[d] /= norm
                    }
                }
                clusterStates[bIdx].centroid = newCentroid
                clusterStates[bIdx].speechSeconds += segDuration
            } else {
                // Create new cluster
                let nextNum = clusterStates.count + 1
                let newClusterId = "c_\(meetingId)_\(nextNum)"
                let newCluster = ClusterState(
                    id: newClusterId,
                    label: "Speaker \(nextNum)",
                    segmentIndices: [idx],
                    centroid: item.embedding,
                    speechSeconds: segDuration
                )
                clusterStates.append(newCluster)
            }
        }
        
        // 5. Build TimedSpeakerSegments and SpeakerClusters
        var timedSegments: [TimedSpeakerSegment] = []
        for cluster in clusterStates {
            for sIdx in cluster.segmentIndices {
                let item = segmentItems[sIdx]
                timedSegments.append(TimedSpeakerSegment(
                    speakerId: cluster.id,
                    start: item.startSec,
                    end: item.endSec,
                    embedding: item.embedding
                ))
            }
        }
        
        // Sort segments chronologically and merge adjacent slices with same speaker
        timedSegments.sort { $0.start < $1.start }
        var mergedSegments: [TimedSpeakerSegment] = []
        for seg in timedSegments {
            if let last = mergedSegments.last, last.speakerId == seg.speakerId && abs(seg.start - last.end) < 0.25 {
                mergedSegments[mergedSegments.count - 1] = TimedSpeakerSegment(
                    speakerId: last.speakerId,
                    start: last.start,
                    end: max(last.end, seg.end),
                    embedding: last.embedding
                )
            } else {
                mergedSegments.append(seg)
            }
        }
        timedSegments = mergedSegments
        
        let finalClusters = clusterStates.map { c in
            SpeakerCluster(
                id: c.id,
                meetingId: meetingId,
                trackId: trackId,
                label: c.label,
                centroid: c.centroid,
                speechSeconds: c.speechSeconds,
                assignment: "suggested",
                confidence: 0.85
            )
        }
        
        return DiarizationResult(
            segments: timedSegments,
            clusters: finalClusters,
            speechDuration: totalSpeechDuration,
            totalDuration: totalDuration
        )
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count && !a.isEmpty else { return 0.0 }
        var dot: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 1e-9 ? (dot / denom) : 0.0
    }
}
