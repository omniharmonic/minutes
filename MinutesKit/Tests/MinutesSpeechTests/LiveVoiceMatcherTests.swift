import Testing
import MinutesCore
@testable import MinutesSpeech

private struct CaptionSpeakerBackend: SpeakerDiarizationBackend {
    var segments: [TrainedSpeakerSegment]
    func diarize(samples: [Float], config: DiarizationConfig) async throws -> [TrainedSpeakerSegment] { segments }
}
struct LiveVoiceMatcherTests {
    let vector: [Float] = [1] + Array(repeating: 0, count: 255)
    let person = Person(id: "synthetic", displayName: "Test speaker")
    func segment(_ id: String = "one", start: Double = 0, end: Double = 6) -> TrainedSpeakerSegment {
        .init(speakerID: id, start: start, end: end, embedding: vector)
    }
    func identify(_ segments: [TrainedSpeakerSegment], seconds: Double = 30, model: String = SpeakerEmbeddingModel.trainedID, rate: Double = 16_000) async throws -> String? {
        let matcher = LiveVoiceMatcher(backend: CaptionSpeakerBackend(segments: segments))
        return try await matcher.name(samples: Array(repeating: 0.1, count: Int(rate * 8)), rate: rate,
            people: [person], voiceprints: [Voiceprint(personId: person.id, model: model, vector: vector, speechSeconds: seconds)])
    }
    @Test func compatibleConfirmedVoiceCanNameSingleSpeakerWindow() async throws {
        #expect(try await identify([segment()]) == person.displayName)
        #expect(try await identify([segment()], rate: 48_000) == person.displayName)
    }
    @Test func mixedOverlappingShortAndInvalidWindowsRemainUnnamed() async throws {
        for segments in [[segment(end: 3), segment("two", start: 3, end: 7)],
                         [segment(end: 5), segment(start: 4, end: 7)],
                         [segment(end: 3)], [segment(end: 10)], []] {
            #expect(try await identify(segments) == nil)
        }
    }
    @Test func shortOrIncompatibleProfilesCannotNameLiveSpeech() async throws {
        #expect(try await identify([segment()], seconds: 2) == nil)
        #expect(try await identify([segment()], model: "legacy") == nil)
    }
}
