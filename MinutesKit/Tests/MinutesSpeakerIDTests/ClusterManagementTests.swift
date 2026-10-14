import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSpeakerID

@Suite("Cluster Management & Centroid Tests")
struct ClusterManagementTests {
    
    @Test("VectorMath centroid computes average vector and L2 normalizes to length 1.0")
    func testCentroidCalculationAndNormalization() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]
        
        let centroid = VectorMath.computeCentroid(vectors: [v1, v2])
        #expect(centroid.count == 3)
        
        let norm = VectorMath.l2Norm(centroid)
        #expect(abs(norm - 1.0) < 1e-5)
        
        // Components should be equal for orthogonal inputs: 1/sqrt(2) ≈ 0.7071
        #expect(abs(Double(centroid[0]) - Double(centroid[1])) < 1e-5)
        #expect(abs(Double(centroid[0]) - (1.0 / sqrt(2.0))) < 1e-4)
    }
    
    @Test("Weighted centroid prioritizes vector with higher speech seconds weight")
    func testWeightedCentroid() {
        let v1: [Float] = [1.0, 0.0]
        let v2: [Float] = [0.0, 1.0]
        
        // Weight 9.0 on v1, 1.0 on v2
        let weighted = VectorMath.computeWeightedCentroid(vectors: [v1, v2], weights: [9.0, 1.0])
        #expect(weighted.count == 2)
        #expect(weighted[0] > weighted[1])
        #expect(abs(VectorMath.l2Norm(weighted) - 1.0) < 1e-5)
    }
    
    @Test("Cosine distance equals 1.0 minus cosine similarity")
    func testCosineDistance() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]
        let v3: [Float] = [1.0, 0.0, 0.0]
        
        let distOrthogonal = VectorMath.cosineDistance(v1, v2)
        let distIdentical = VectorMath.cosineDistance(v1, v3)
        
        #expect(abs(distOrthogonal - 1.0) < 1e-5)
        #expect(abs(distIdentical - 0.0) < 1e-5)
    }
    
    @Test("ClusterManager merge combines centroids and sums speech duration")
    func testClusterMerge() {
        let manager = ClusterManager()
        
        let c1 = SpeakerCluster(
            id: "c1",
            meetingId: "m",
            trackId: "t",
            label: "Speaker A",
            centroid: [1.0, 0.0],
            speechSeconds: 60.0
        )
        let c2 = SpeakerCluster(
            id: "c2",
            meetingId: "m",
            trackId: "t",
            label: "Speaker B",
            centroid: [0.0, 1.0],
            speechSeconds: 40.0
        )
        
        let merged = manager.merge(clusters: [c1, c2], targetName: "Alice & Bob")
        #expect(merged.label == "Alice & Bob")
        #expect(merged.assignment == "user")
        #expect(abs(merged.speechSeconds - 100.0) < 1e-5)
        #expect(abs(VectorMath.l2Norm(merged.centroid) - 1.0) < 1e-5)
    }
    
    @Test("ClusterManager split divides cluster by timestamp boundary")
    func testClusterSplit() {
        let manager = ClusterManager()
        
        let cluster = SpeakerCluster(
            id: "c_orig",
            meetingId: "m",
            trackId: "t",
            label: "Speaker X",
            centroid: [0.7071, 0.7071],
            speechSeconds: 100.0
        )
        
        let u1 = Utterance(id: 1, meetingId: "m", clusterId: "c_orig", speakerName: "Speaker X", start: 10.0, end: 20.0, text: "Early remark")
        let u2 = Utterance(id: 2, meetingId: "m", clusterId: "c_orig", speakerName: "Speaker X", start: 70.0, end: 80.0, text: "Later remark")
        
        let (part1, part2, updatedUtterances) = manager.split(
            cluster: cluster,
            boundaryTimestamp: 50.0,
            utterances: [u1, u2]
        )
        
        #expect(part1.id == "c_orig_part1")
        #expect(part2.id == "c_orig_part2")
        #expect(updatedUtterances.count == 2)
        #expect(updatedUtterances[0].clusterId == part1.id)
        #expect(updatedUtterances[1].clusterId == part2.id)
    }
}
