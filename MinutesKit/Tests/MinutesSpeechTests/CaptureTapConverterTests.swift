import AVFoundation
import Testing
@testable import MinutesSpeech

struct CaptureTapConverterTests {
    @Test("Native mono/stereo input is converted from actual buffers into fixed PCM", arguments: [48_000.0, 44_100.0])
    func nativePCM(sampleRate: Double) throws {
        let channels: AVAudioChannelCount = sampleRate == 48_000 ? 1 : 2
        let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let converter = CaptureTapConverter(outputFormat: target)
        var samples: [Int16] = []
        var offset = 0
        while offset < Int(sampleRate) {
            let count = min(1024, Int(sampleRate) - offset)
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count))!
            input.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(channels) {
                for index in 0..<count {
                    input.floatChannelData![channel][index] = Float(sin(2 * Double.pi * 440 * Double(index + offset) / sampleRate) * 0.5)
                }
            }
            if let output = try converter.convert(input) {
                #expect(output.format == target)
                samples.append(contentsOf: UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
            }
            offset += count
        }
        #expect(samples.count > 15_000 && samples.count <= 16_128)
        let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        let frequency = Double(crossings) / (Double(samples.count) / 16_000)
        #expect(abs(frequency - 440) < 3)
    }

    @Test("A native format change retains fixed PCM without reusing stale conversion state")
    func formatIsNotReusedAcrossGraphs() throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let converter = CaptureTapConverter(outputFormat: target)
        let first = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 1024)!
        first.frameLength = 1024
        first.floatChannelData![0].update(repeating: 0, count: 1024)
        _ = try converter.convert(first)
        let different = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!, frameCapacity: 1024)!
        different.frameLength = 1024
        different.floatChannelData![0].update(repeating: 0, count: 1024)
        #expect(try converter.convert(different)?.format == target)
        #expect(try CaptureTapConverter(outputFormat: target).convert(different) != nil)
    }
}
