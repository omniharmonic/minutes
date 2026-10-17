import Testing
@testable import MinutesSpeech

struct CaptionSilenceGateTests {
    @Test func recognitionErrorsAreQuietEndsOnlyAfterTwoSecondsWithoutSignal() {
        #expect(CaptionSilenceGate.isQuietTail(frames: 48_000, lastSignal: 16_000, rate: 16_000))
        #expect(!CaptionSilenceGate.isQuietTail(frames: 48_000, lastSignal: 40_000, rate: 16_000))
        #expect(!CaptionSilenceGate.isQuietTail(frames: 48_000, lastSignal: 50_000, rate: 16_000))
        #expect(!CaptionSilenceGate.isQuietTail(frames: 48_000, lastSignal: 0, rate: .nan))
    }
    @Test func digitalSilenceDoesNotOpenAnotherRecognizer() {
        #expect(!CaptionSilenceGate.containsSignal(Array(repeating: 0, count: 4800)))
        #expect(!CaptionSilenceGate.containsSignal([.nan, .infinity]))
        #expect(CaptionSilenceGate.containsSignal([0, -0.0002, 0]))
    }
}
