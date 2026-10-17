import AVFoundation
import Testing
@testable import MinutesSpeech

struct CaptureLevelMeterTests {
    @Test("Real quiet PCM signals are visible on the decibel display while silence stays zero")
    func quietSpeechAndSilence() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<256 { samples[index] = index.isMultiple(of: 2) ? 0.005 : -0.005 }
        let rms = CaptureLevelMeter.rms(buffer)
        #expect(abs(rms - 0.005) < 0.00001)
        #expect(CaptureLevelMeter.displayLevel(rms: rms) > 0.2)
        for index in 0..<256 { samples[index] = 0 }
        #expect(CaptureLevelMeter.displayLevel(rms: CaptureLevelMeter.rms(buffer)) == 0)
        #expect(CaptureLevelMeter.displayLevel(rms: .nan) == 0)
        #expect(CaptureLevelMeter.displayLevel(rms: .infinity) == 0)
    }

    @Test("Interleaved stereo integer microphone data is measured without planar indexing")
    func interleavedIntegerInput() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let samples = try #require(buffer.int16ChannelData)[0]
        for index in 0..<256 { samples[index * 2] = 16384; samples[index * 2 + 1] = 0 }
        #expect(abs(CaptureLevelMeter.rms(buffer) - Float(sqrt(0.125))) < 0.00001)
        #expect(CaptureLevelMeter.displayLevel(rms: CaptureLevelMeter.rms(buffer)) > 0.8)
    }
}
