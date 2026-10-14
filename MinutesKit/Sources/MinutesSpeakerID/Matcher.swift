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
                let effectiveScore = isAttendee ? (maxSim + attendeeBonus) : maxSim
                
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
            
            let thresh = item.isAttendee ? (autoThreshold - attendeeBonus) : autoThreshold
            let suggThresh = item.isAttendee ? (suggestThreshold - attendeeBonus) : suggestThreshold
            
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
