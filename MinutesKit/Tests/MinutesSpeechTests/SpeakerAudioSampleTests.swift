import Foundation
import Testing
import MinutesCore
import AVFoundation
import CoreMedia
@testable import MinutesSpeech

struct SpeakerAudioSampleTests {
    private func utterance(_ start: Double, _ end: Double, cluster: String = "speaker") -> Utterance {
        Utterance(id: 1, meetingId: "fixture", clusterId: cluster, speakerName: "Fictional speaker",
                  start: start, end: end, text: "Synthetic sample")
    }

    @Test func invalidOrOtherSpeakerTimingCannotBecomeAPlayableSample() {
        #expect(SpeakerAudioSample(utterances: [utterance(.nan, 10), utterance(-1, 2),
            utterance(4, 3), utterance(1, .infinity), utterance(0, 5, cluster: "other")], clusterID: "speaker") == nil)
    }

    @Test func sampleUsesCleanChronologicalExcerptAndCapsLongSpeech() throws {
        let clean = try #require(SpeakerAudioSample(utterances: [utterance(20, 25), utterance(0, 30), utterance(5, 9)], clusterID: "speaker"))
        #expect(clean.start == 5)
        #expect(clean.end == 9)
        let long = try #require(SpeakerAudioSample(utterances: [utterance(15, 60)], clusterID: "speaker"))
        #expect(long.start == 15)
        #expect(long.end == 27)
    }

    @Test func importedTranscriptCannotOfferUnrelatedAudio() throws {
        let cluster = SpeakerCluster(meetingId: "fixture", trackId: "system", label: "A")
        let transcript = Meeting(title: "Fixture", platform: "transcript_import", audioPath: "/tmp/unrelated.wav")
        #expect(throws: (any Error).self) { try SpeakerAudioSample.audioPath(meeting: transcript, cluster: cluster) }
        let imported = Meeting(title: "Fixture", audioPath: "/tmp/fixture.wav")
        #expect(try SpeakerAudioSample.audioPath(meeting: imported, cluster: cluster) == "/tmp/fixture.wav")
    }

    @Test func pairedSpeakerPlaybackUsesAlignedSourceEvenWhenMixCancelsToSilence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-sample-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        for (source, value) in [(CaptureAudioSource.system, Float(0.3)), (.microphone, Float(-0.3))] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            buffer.floatChannelData![0].update(repeating: value, count: 48000)
            try archive.append(buffer, source: source, presentationTime: CMTime(value: 100, timescale: 1))
        }
        let capture = try archive.finish()
        let mixedURL = try #require(capture.processingURL)
        let meeting = Meeting(id: "fixture", title: "Fixture", audioPath: mixedURL.path)
        let mixed = try AudioDecoder.decode(fileURL: mixedURL)
        #expect(mixed.samples.allSatisfy { abs($0) < 0.001 })
        for source in ["system", "microphone"] {
            let cluster = SpeakerCluster(meetingId: meeting.id, trackId: source, label: "Fictional speaker")
            let path = try SpeakerAudioSample.audioPath(meeting: meeting, cluster: cluster)
            #expect(path == root.appendingPathComponent("aligned-\(source).caf").path)
            let decoded = try AudioDecoder.decode(fileURL: URL(fileURLWithPath: path))
            #expect(decoded.samples.contains { abs($0) > 0.1 })
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("aligned-system.caf"))
        let cluster = SpeakerCluster(meetingId: meeting.id, trackId: "system", label: "Fictional speaker")
        #expect(throws: (any Error).self) { try SpeakerAudioSample.audioPath(meeting: meeting, cluster: cluster) }
    }
}
