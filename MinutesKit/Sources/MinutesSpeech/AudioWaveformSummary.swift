import Foundation
@preconcurrency import AVFoundation

/// A coarse loudness envelope of a saved recording for drawing a scrubbable waveform.
public enum AudioWaveformSummary {
    /// Peak absolute amplitude per bin, normalised so the loudest bin is 1.
    /// Multichannel files are folded to their loudest channel per frame.
    public static func peaks(url: URL, bins: Int = 160) throws -> [Float] {
        precondition(bins > 0)
        let file = try AVAudioFile(forReading: url)
        let frames = file.length
        guard frames > 0 else { return [] }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var peaks = [Float](repeating: 0, count: bins)
        var position: AVAudioFramePosition = 0
        while position < frames {
            try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(frames - position)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var sample: Float = 0
                for channel in 0..<Int(format.channelCount) { sample = max(sample, abs(channels[channel][frame])) }
                let bin = min(bins - 1, Int((position + AVAudioFramePosition(frame)) * AVAudioFramePosition(bins) / frames))
                if sample > peaks[bin] { peaks[bin] = sample }
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}
