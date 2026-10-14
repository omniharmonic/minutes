import Foundation
import MinutesCore

public enum VectorMath {
    /// Computes cosine similarity between two float vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        
        var dot: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0
        
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-12 else { return 0.0 }
        return dot / denom
    }
    
    /// Computes cosine distance between two float vectors: 1.0 - cosineSimilarity(a, b)
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        return 1.0 - cosineSimilarity(a, b)
    }
    
    /// Computes L2 norm (Euclidean length) of a vector.
    public static func l2Norm(_ v: [Float]) -> Double {
        var sumSquares: Double = 0.0
        for x in v {
            let d = Double(x)
            sumSquares += d * d
        }
        return sqrt(sumSquares)
    }
    
    /// Normalizes a vector to unit length (L2 norm = 1.0).
    public static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = l2Norm(v)
        guard norm > 1e-12 else {
            return v
        }
        return v.map { Float(Double($0) / norm) }
    }
    
    /// Computes centroid of a collection of vectors: average followed by L2 normalization.
    public static func computeCentroid(vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        let dim = first.count
        var sum = [Double](repeating: 0.0, count: dim)
        var count = 0
        
        for v in vectors where v.count == dim {
            for i in 0..<dim {
                sum[i] += Double(v[i])
            }
            count += 1
        }
        
        guard count > 0 else { return [] }
        let mean = sum.map { Float($0 / Double(count)) }
        return l2Normalize(mean)
    }
    
    /// Computes weighted centroid: sum(w_i * v_i) / sum(w_i), followed by L2 normalization.
    public static func computeWeightedCentroid(vectors: [[Float]], weights: [Double]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        let dim = first.count
        guard vectors.count == weights.count else {
            return computeCentroid(vectors: vectors)
        }
        
        var sum = [Double](repeating: 0.0, count: dim)
        var totalWeight = 0.0
        
        for (v, w) in zip(vectors, weights) where v.count == dim && w > 0 {
            for i in 0..<dim {
                sum[i] += Double(v[i]) * w
            }
            totalWeight += w
        }
        
        guard totalWeight > 1e-12 else {
            return computeCentroid(vectors: vectors)
        }
        
        let weightedMean = sum.map { Float($0 / totalWeight) }
        return l2Normalize(weightedMean)
    }
    
    /// Deterministic 2D projection for centroid visualization scatter plots.
    /// Maps high-dimensional embedding vectors into [-1.0, 1.0] 2D coordinates.
    public static func project2D(_ vector: [Float]) -> (x: Double, y: Double) {
        guard !vector.isEmpty else { return (0.0, 0.0) }
        var xSum: Double = 0.0
        var ySum: Double = 0.0
        
        for (i, val) in vector.enumerated() {
            let angle = (Double(i) / Double(vector.count)) * 2.0 * .pi
            let weight = Double(val)
            xSum += weight * cos(angle)
            ySum += weight * sin(angle)
        }
        
        // Normalize coordinates to [-1, 1] range
        let scale = sqrt(Double(vector.count)) * 0.25
        let x = max(-1.0, min(1.0, xSum / max(1.0, scale)))
        let y = max(-1.0, min(1.0, ySum / max(1.0, scale)))
        return (x, y)
    }
    
    /// Groups high-dimensional embedding features into frequency/density bins for bar-chart visualizer.
    public static func binFeatures(_ vector: [Float], bins: Int = 16) -> [Float] {
        guard !vector.isEmpty, bins > 0 else { return [] }
        let chunkSize = max(1, vector.count / bins)
        var result = [Float]()
        
        for b in 0..<bins {
            let start = b * chunkSize
            let end = min(vector.count, start + chunkSize)
            if start >= vector.count {
                result.append(0.0)
                continue
            }
            let slice = vector[start..<end]
            let avg = slice.reduce(0.0) { $0 + abs($1) } / Float(slice.count)
            result.append(avg)
        }
        return result
    }
}

public struct MatchResult: Sendable {
    public let clusterId: String
    public let personId: String?
    public let personName: String?
    public let assignment: String // "auto", "suggested", "unassigned"
    public let confidence: Double
    
    public init(clusterId: String, personId: String? = nil, personName: String? = nil, assignment: String = "unassigned", confidence: Double = 0.0) {
        self.clusterId = clusterId
        self.personId = personId
        self.personName = personName
        self.assignment = assignment
        self.confidence = confidence
    }
}

public final class SpeakerMatcher: Sendable {
    public let autoThreshold: Double
    public let suggestThreshold: Double
    public let attendeeBonus: Double
    
    public init(autoThreshold: Double = 0.68, suggestThreshold: Double = 0.52, attendeeBonus: Double = 0.08) {
        self.autoThreshold = autoThreshold
        self.suggestThreshold = suggestThreshold
        self.attendeeBonus = attendeeBonus
    }
    
    /// Matches speaker clusters to candidate persons using voiceprints and calendar priors.
    public func match(
        clusters: [SpeakerCluster],
        people: [Person],
        voiceprints: [Voiceprint],
        attendeePersonIds: Set<String>
    ) -> [MatchResult] {
        // Map personId to voiceprint vectors
        var vpMap: [String: [[Float]]] = [:]
        for vp in voiceprints {
            vpMap[vp.personId, default: []].append(vp.vector)
        }
        
        let personNameMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
        
        // Compute pairwise similarity scores: (clusterId, personId) -> score
        struct CandidateScore {
            let clusterId: String
            let personId: String
            let score: Double
            let isAttendee: Bool
        }
        
        var allScores: [CandidateScore] = []
        
        for c in clusters {
            guard !c.centroid.isEmpty else { continue }
            
            for p in people {
                guard let vps = vpMap[p.id], !vps.isEmpty else { continue }
                
                // Max cosine similarity against any voiceprint of this person
                var maxSim = 0.0
                for v in vps {
                    let sim = VectorMath.cosineSimilarity(c.centroid, v)
                    if sim > maxSim {
                        maxSim = sim
                    }
                }
                
                let isAttendee = attendeePersonIds.contains(p.id)
                // Acoustic floor: calendar prior only applies if voice has plausible acoustic similarity (>= 0.40)
                // and effective score is strictly clamped to [0.0, 1.0]
                let boosted = (isAttendee && maxSim >= 0.40) ? (maxSim + attendeeBonus) : maxSim
                let effectiveScore = min(1.0, max(0.0, boosted))
                
                allScores.append(CandidateScore(
                    clusterId: c.id,
                    personId: p.id,
                    score: effectiveScore,
                    isAttendee: isAttendee
                ))
            }
        }
        
        // Greedy 1-to-1 matching (ordered by descending score)
        let sorted = allScores.sorted { $0.score > $1.score }
        var matchedClusters = Set<String>()
        var matchedPeople = Set<String>()
        var resultsMap: [String: MatchResult] = [:]
        
        for item in sorted {
            guard !matchedClusters.contains(item.clusterId), !matchedPeople.contains(item.personId) else {
                continue
            }
            
            let thresh = autoThreshold
            let suggThresh = suggestThreshold
            
            let assignment: String
            if item.score >= thresh {
                assignment = "auto"
            } else if item.score >= suggThresh {
                assignment = "suggested"
            } else {
                continue
            }
            
            matchedClusters.insert(item.clusterId)
            matchedPeople.insert(item.personId)
            
            resultsMap[item.clusterId] = MatchResult(
                clusterId: item.clusterId,
                personId: item.personId,
                personName: personNameMap[item.personId],
                assignment: assignment,
                confidence: item.score
            )
        }
        
        // Fill remaining unassigned clusters
        return clusters.map { c in
            if let m = resultsMap[c.id] {
                return m
            }
            return MatchResult(clusterId: c.id, assignment: "unassigned", confidence: 0.0)
        }
    }
}
