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

/// Synthetic voice windows shaped like the calibration data: windows from one
/// speaker are about 0.7 similar to each other, different speakers near 0.
struct LiveSpeakerGroupingTests {
    struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Float(Double(z ^ (z >> 31)) / Double(UInt64.max)) * 2 - 1
        }
        mutating func vector() -> [Float] { (0..<256).map { _ in next() } }
    }
    static func window(_ voice: [Float], _ generator: inout Generator) -> [Float] {
        let noise = generator.vector()
        let n = VectorMath.l2Normalize(noise), v = VectorMath.l2Normalize(voice)
        return zip(v, n).map { $0 * 0.84 + $1 * 0.54 }   // pairwise similarity ≈ 0.7
    }

    @Test func oneSpeakerStaysOneGroupAcrossNoisyWindows() {
        var generator = Generator(state: 1)
        let voice = generator.vector()
        var groups = LiveSpeakerClusters()
        let labels = (0..<80).compactMap { _ in groups.label(for: Self.window(voice, &generator)) }
        #expect(Set(labels.map { groups.resolve($0) }) == ["Speaker 1"])
        #expect(labels.count == 80)
    }

    @Test func aSevenPersonCallFindsSevenSpeakers() {
        var generator = Generator(state: 7)
        let voices = (0..<7).map { _ in generator.vector() }
        var groups = LiveSpeakerClusters()
        var byVoice: [Int: Set<String>] = [:]
        for turn in 0..<350 {
            let speaker = (turn / 3) % 7
            if let label = groups.label(for: Self.window(voices[speaker], &generator)) { byVoice[speaker, default: []].insert(label) }
        }
        let resolved = byVoice.mapValues { Set($0.map { groups.resolve($0) }) }
        #expect(resolved.values.allSatisfy { $0.count == 1 })
        #expect(Set(resolved.values.flatMap { $0 }).count == 7)
    }

    @Test func groupsThatTurnOutToBeOneVoiceMerge() {
        var groups = LiveSpeakerClusters()
        let base: [Float] = [1, 0] + Array(repeating: 0, count: 254)
        let edge: [Float] = [0.36, 0.93] + Array(repeating: 0, count: 254)   // 0.36 to base: starts a new group
        let between: [Float] = [0.8, 0.6] + Array(repeating: 0, count: 254)
        let first = groups.label(for: base), second = groups.label(for: edge)
        #expect(first == "Speaker 1" && second == "Speaker 2")
        for _ in 0..<4 { _ = groups.label(for: between) }
        #expect(groups.resolve("Speaker 2") == groups.resolve("Speaker 1"))
    }

    @Test func unclearEvidenceStaysUnnamedAndVoicesBeyondTheCapAreNotInvented() {
        var groups = LiveSpeakerClusters()
        let base: [Float] = [1, 0] + Array(repeating: 0, count: 254)
        let unclear: [Float] = [0.5, 0.866] + Array(repeating: 0, count: 254)   // 0.5: neither join nor new
        _ = groups.label(for: base)
        #expect(groups.label(for: unclear) == nil)
        var crowded = LiveSpeakerClusters()
        let labels = (0..<20).map { i -> String? in
            var v = [Float](repeating: 0, count: 256); v[i] = 1; return crowded.label(for: v)
        }
        #expect(labels.compactMap { $0 }.count == LiveSpeakerClusters.maximumGroups)
    }
}
