import Testing
@testable import MinutesSpeakerID

struct LiveSpeakerClustersTests {
    @Test func anonymousVoicesRemainDistinctAndRepeatConsistently() {
        var groups = LiveSpeakerClusters()
        let a: [Float] = [1, 0] + Array(repeating: 0, count: 254)
        let b: [Float] = [0, 1] + Array(repeating: 0, count: 254)
        let first = groups.label(for: a)
        let second = groups.label(for: b)
        let repeatFirst = groups.label(for: a)
        #expect(first == "Speaker 1")
        #expect(second == "Speaker 2")
        #expect(repeatFirst == first)
        let invalid = groups.label(for: [1])
        #expect(invalid == nil)
    }
}
