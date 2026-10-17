import Testing
import Foundation
import AVFoundation
@testable import MinutesCore
@testable import MinutesSpeech
@testable import MinutesSpeakerID

@Suite("Speech plumbing and experimental spectral utility tests")
struct PipelineSpeechTests {
    
    // Helper to generate a valid WAV file in a temporary location
    static func createSynthesizedWav(
        durationSec: Double = 4.0,
        sampleRate: Double = 16000.0,
        speaker1Freq: Double = 180.0,
        speaker2Freq: Double = 350.0
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_speech_\(UUID().uuidString).wav")
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
        let totalFrames = AVAudioFrameCount(durationSec * sampleRate)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "TestAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"])
        }
        pcmBuffer.frameLength = totalFrames
        
        // Fill buffer with two distinct speaker regions separated by a silence gap
        // [0.0, 1.8s]: Speaker 1 (180 Hz with harmonics)
        // [1.8, 2.2s]: Silence
        // [2.2, 4.0s]: Speaker 2 (350 Hz with harmonics)
        let channelData = pcmBuffer.floatChannelData![0]
        for frame in 0..<Int(totalFrames) {
            let t = Double(frame) / sampleRate
            if t < 1.8 {
                // Speaker 1 voice tone
                let v = 0.5 * sin(2.0 * .pi * speaker1Freq * t) + 0.25 * sin(4.0 * .pi * speaker1Freq * t)
                channelData[frame] = Float(v)
            } else if t < 2.2 {
                // Silence
                channelData[frame] = 0.0
            } else {
                // Speaker 2 voice tone
                let v = 0.5 * sin(2.0 * .pi * speaker2Freq * t) + 0.25 * sin(4.0 * .pi * speaker2Freq * t)
                channelData[frame] = Float(v)
            }
        }
        
        try audioFile.write(from: pcmBuffer)
        return fileURL
    }
    
    @Test("AudioDecoder decodes 16kHz mono PCM accurately from WAV")
    func testAudioDecoderSuccess() throws {
        let wavURL = try Self.createSynthesizedWav(durationSec: 3.0)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        
        let decoded = try AudioDecoder.decode(fileURL: wavURL, targetSampleRate: 16000.0)
        #expect(decoded.sampleRate == 16000.0)
        #expect(decoded.channelCount == 1)
        #expect(abs(decoded.duration - 3.0) < 0.1)
        #expect(decoded.samples.count == Int(decoded.sampleRate * decoded.duration))
        #expect(!decoded.samples.isEmpty)
    }
    
    @Test("AudioDecoder rejects non-existent, empty, and corrupt audio files")
    func testAudioDecoderNegativeCases() throws {
        // Non-existent file
        let bogusURL = URL(fileURLWithPath: "/tmp/non_existent_audio_\(UUID().uuidString).wav")
        #expect(throws: AudioDecodeError.self) {
            try AudioDecoder.decode(fileURL: bogusURL)
        }
        
        // Empty 0-byte file
        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString).wav")
        try Data().write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        #expect(throws: AudioDecodeError.self) {
            try AudioDecoder.decode(fileURL: emptyURL)
        }
        
        // Corrupt file (random binary noise)
        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt_\(UUID().uuidString).wav")
        let junkBytes = Data([0xFF, 0xFE, 0x00, 0x12, 0x34, 0x56, 0x78])
        try junkBytes.write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        #expect(throws: AudioDecodeError.self) {
            try AudioDecoder.decode(fileURL: corruptURL)
        }
    }
    
    @Test("EmbeddingService extracts 256-dimensional L2-normalized acoustic vectors")
    func testEmbeddingServiceNormAndDimension() {
        // Generate 1 second of 200 Hz tone
        let sampleRate: Double = 16000.0
        let frameCount = Int(sampleRate)
        var samples = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            samples[i] = Float(0.5 * sin(2.0 * .pi * 200.0 * t))
        }
        
        let embedding = ExperimentalSpectralEmbedding.extractEmbedding(samples: samples, sampleRate: sampleRate)
        #expect(embedding.count == 256)
        
        // Check L2 norm is 1.0 within epsilon
        let norm = sqrt(embedding.reduce(0.0) { $0 + Double($1 * $1) })
        #expect(abs(norm - 1.0) < 0.001)
    }
    
    @Test("EmbeddingService separates distinct acoustic pitch profiles")
    func testEmbeddingServicePitchSeparation() {
        let sampleRate: Double = 16000.0
        let n = Int(sampleRate * 1.5)
        
        // Voice A: low pitch (130 Hz fundamental)
        var voiceA1 = [Float](repeating: 0, count: n)
        var voiceA2 = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            voiceA1[i] = Float(0.6 * sin(2 * .pi * 130 * t) + 0.3 * sin(4 * .pi * 130 * t))
            voiceA2[i] = Float(0.5 * sin(2 * .pi * 130 * t + 0.2) + 0.35 * sin(4 * .pi * 130 * t))
        }
        
        // Voice B: high pitch (380 Hz fundamental)
        var voiceB = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            voiceB[i] = Float(0.6 * sin(2 * .pi * 380 * t) + 0.3 * sin(4 * .pi * 380 * t))
        }
        
        let embA1 = ExperimentalSpectralEmbedding.extractEmbedding(samples: voiceA1, sampleRate: sampleRate)
        let embA2 = ExperimentalSpectralEmbedding.extractEmbedding(samples: voiceA2, sampleRate: sampleRate)
        let embB = ExperimentalSpectralEmbedding.extractEmbedding(samples: voiceB, sampleRate: sampleRate)
        
        let simA1_A2 = VectorMath.cosineSimilarity(embA1, embA2)
        let simA1_B = VectorMath.cosineSimilarity(embA1, embB)
        
        // Same voice should have much higher similarity than distinct pitch voice
        #expect(simA1_A2 > 0.95)
        #expect(simA1_B < 0.85)
        #expect(simA1_A2 > simA1_B + 0.12)
    }
    
    @Test("Experimental spectral utility segments synthetic tones; no speaker accuracy claim")
    func testDiarizationServiceClusters() throws {
        let wavURL = try Self.createSynthesizedWav(durationSec: 4.0, speaker1Freq: 150.0, speaker2Freq: 400.0)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        
        let decoded = try AudioDecoder.decode(fileURL: wavURL)
        let diarizer = ExperimentalSpectralDiarizer()
        let result = diarizer.diarize(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            meetingId: "m_test_diarize"
        )
        
        #expect(!result.segments.isEmpty)
        #expect(!result.clusters.isEmpty)
        #expect(result.speechDuration > 0.0)
        
        // Each cluster must have 256-dim centroid and positive speechSeconds
        for cluster in result.clusters {
            #expect(cluster.centroid.count == 256)
            #expect(cluster.speechSeconds > 0.0)
            #expect(cluster.meetingId == "m_test_diarize")
        }
    }
    
    @Test("Pipeline routes explicit fixture diarization and transcript into utterances")
    func testPipelineOrchestratorEndToEnd() async throws {
        let wavURL = try Self.createSynthesizedWav(durationSec: 4.0, speaker1Freq: 160.0, speaker2Freq: 360.0)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        
        let orchestrator = PipelineOrchestrator(
            asrService: FixtureTranscriptionBackend(),
            diarizationService: DiarizationService(backend: FixtureDiarizationBackend())
        )
        let result = try await orchestrator.process(
            meetingId: "m_pipeline_e2e",
            audioURL: wavURL,
            speakerNames: [:]
        )
        
        #expect(result.meetingId == "m_pipeline_e2e")
        #expect(result.audioDuration > 3.5)
        #expect(result.speechDuration > 0.0)
        #expect(!result.words.isEmpty)
        #expect(!result.utterances.isEmpty)
        #expect(!result.clusters.isEmpty)
        
        #expect(result.utterances.allSatisfy { utterance in
            result.clusters.first(where: { $0.id == utterance.clusterId })?.label == utterance.speakerName
        }, "Diarization labels must reach utterances; storage IDs are not speaker display names")

        // Utterance words must match transcript tokens
        let allUtteranceWords = result.utterances.flatMap { $0.words }.map { $0.word }
        #expect(allUtteranceWords.contains("engineering"))
        #expect(allUtteranceWords.contains("architecture"))
    }
}

struct FixtureTranscriptionBackend: SpeechTranscriptionBackend {
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        [ASRWord(word: "engineering", start: 0.25, end: 0.8, confidence: 1),
         ASRWord(word: "architecture", start: 2.25, end: 2.9, confidence: 1)]
    }
}
private struct FilteredTurnRecognitionFixture: SpeechTranscriptionBackend {
    let includeSecondTurn: Bool
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        var words = [ASRWord(word: "first", start: 0.5, end: 5.5, confidence: 0)]
        if includeSecondTurn { words.append(.init(word: "second", start: 6.5, end: 11.5, confidence: 1)) }
        return words
    }
}

extension PipelineSpeechTests {
    @Test(arguments: [false, true])
    func confidenceFilteringCannotSilentlyRemoveSubstantialDetectedSpeech(includeSecondTurn: Bool) async throws {
        let url = try Self.createSynthesizedWav(durationSec: includeSecondTurn ? 12 : 6)
        defer { try? FileManager.default.removeItem(at: url) }
        var first = [Float](repeating: 0, count: 256); first[0] = 1
        var second = [Float](repeating: 0, count: 256); second[1] = 1
        var segments = [TrainedSpeakerSegment(speakerID: "one", start: 0, end: 6, embedding: first)]
        if includeSecondTurn { segments.append(.init(speakerID: "two", start: 6, end: 12, embedding: second)) }
        let pipeline = PipelineOrchestrator(asrService: FilteredTurnRecognitionFixture(includeSecondTurn: includeSecondTurn),
            diarizationService: DiarizationService(backend: FixtureDiarizationBackend(output: segments)))
        let result = try await pipeline.process(meetingId: "filtered-turn", audioURL: url)
        let savedWords = result.utterances.flatMap(\.words)
        #expect(savedWords.map(\.word) == (includeSecondTurn ? ["first", "second"] : ["first"]))
        #expect(savedWords.first?.confidence == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
