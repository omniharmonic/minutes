import Foundation
import Testing
import MinutesCore
import AVFoundation
import CoreMedia
@testable import MinutesSpeech

struct CaptureSourceProcessingTests {
    private func capture() throws -> (URL, SynchronizedCaptureResult) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-pipeline-" + UUID().uuidString)
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        for (source, value) in [(CaptureAudioSource.system, Float(0.3)), (.microphone, Float(-0.3))] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            buffer.floatChannelData![0].update(repeating: value, count: 48000)
            try archive.append(buffer, source: source, presentationTime: CMTime(value: 100, timescale: 1))
        }
        return (root, try archive.finish())
    }

    @Test func cancellingMixCannotDiscardEitherOriginalSource() async throws {
        let (root, capture) = try capture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixedURL = try #require(capture.processingURL)
        let mixed = try AudioDecoder.decode(fileURL: mixedURL)
        #expect(mixed.samples.allSatisfy { abs($0) < 0.001 })
        let backend = IndependentCaptureASR()
        let pipeline = PipelineOrchestrator(asrService: backend,
            diarizationService: DiarizationService(backend: FixtureDiarizationBackend(output: [
                .init(speakerID: "one", start: 0, end: 0.9, embedding: [1] + Array(repeating: 0, count: 255))])))
        let processed = try await pipeline.process(meetingId: "m", audioURL: mixedURL)
        #expect(Set(processed.utterances.map(\.text)) == ["system", "microphone"])
        #expect(Set(processed.clusters.map(\.trackId)) == ["system", "microphone"])
        #expect(await backend.calls == 2)
        let named = try await pipeline.process(meetingId: "m", audioURL: mixedURL,
            speakerNames: ["system_c_m_1": "Fictional Ana", "microphone_c_m_1": "Fictional Ben"])
        #expect(Set(named.utterances.map(\.speakerName)) == ["Fictional Ana", "Fictional Ben"])
        #expect(Set(named.clusters.map(\.label)) == ["Fictional Ana", "Fictional Ben"])
        await #expect(throws: ASRError.self) {
            try await pipeline.process(meetingId: "m", audioURL: mixedURL, speakerNames: ["c_m_1": "Ambiguous identity"])
        }
    }

    @Test func missingAlignedSourceCannotFallBackToTheLossyMix() throws {
        let (root, capture) = try capture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("aligned-microphone.caf"))
        #expect(throws: (any Error).self) { try CaptureSourceProcessing.sources(for: #require(capture.processingURL)) }
        #expect(try CaptureSourceProcessing.sources(for: root.appendingPathComponent("imported.wav")) == nil)
    }

    private func result(_ text: String, start: Double = 1, end: Double = 10) -> PipelineResult {
        PipelineResult(meetingId: "m", audioDuration: 12, sampleRate: 16000, words: [],
            segments: [.init(speakerId: "c", start: start, end: end)],
            clusters: [SpeakerCluster(id: "c", meetingId: "m", trackId: "track_1", label: "Speaker 1")],
            utterances: [Utterance(id: 1, meetingId: "m", clusterId: "c", speakerName: "Speaker 1", start: start, end: end, text: text)], speechDuration: end - start)
    }

    @Test func independentSourceIdentitiesAndSimultaneousSpeechSurvive() {
        let merged = CaptureSourceProcessing.merge(meetingID: "m", results: [
            ("system", result("The caller describes the telescope inspection and its next steps.")),
            ("microphone", result("I will check the lens specification before Tuesday."))])
        #expect(merged.clusters.count == 2)
        #expect(Set(merged.clusters.map(\.id)).count == 2)
        #expect(Set(merged.utterances.map(\.clusterId)) == Set(merged.clusters.map(\.id)))
        #expect(merged.utterances.count == 2)
        #expect(Set(merged.utterances.map(\.id)).count == 2)
    }

    @Test func onlyLongExactOverlappingCrossSourceEchoIsRemoved() {
        let phrase = "The caller will inspect the telescope and check its lens on Tuesday."
        let merged = CaptureSourceProcessing.merge(meetingID: "m", results: [
            ("system", result(phrase)), ("microphone", result(phrase))])
        #expect(merged.utterances.count == 1)
        #expect(merged.utterances.first?.clusterId.hasPrefix("system_") == true)
        let short = CaptureSourceProcessing.merge(meetingID: "m", results: [
            ("system", result("Thank you")), ("microphone", result("Thank you"))])
        #expect(short.utterances.count == 2)
        let later = CaptureSourceProcessing.merge(meetingID: "m", results: [
            ("system", result(phrase)), ("microphone", result(phrase, start: 11, end: 12))])
        #expect(later.utterances.count == 2)
    }
}

private actor IndependentCaptureASR: SpeechTranscriptionBackend {
    private(set) var calls = 0
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        calls += 1
        let samples = try AudioDecoder.decode(fileURL: audioURL).samples
        let mean = samples.reduce(0, +) / Float(samples.count)
        guard abs(mean) > 0.1 else { throw ASRError.noSpeechDetected }
        return [.init(word: mean > 0 ? "system" : "microphone", start: 0.1, end: 0.8)]
    }
}
