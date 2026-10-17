import Foundation
import AVFoundation

/// Converts actual native buffers to fixed PCM. Rebuild conversion state when a
/// route changes format before its graph notification reaches the service.
final class CaptureTapConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        func failure() -> NSError {
            NSError(domain: "AudioCaptureService", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "The microphone buffer format changed or could not be converted. Any saved audio was preserved."])
        }
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { throw failure() }
        if sourceFormat?.isEqual(buffer.format) != true {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { throw failure() }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate + 1024)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw failure() }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &error) { _, result in
            if consumed { result.pointee = .noDataNow; return nil }
            consumed = true
            result.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? failure() }
        return converted.frameLength > 0 ? converted : nil
    }
}
