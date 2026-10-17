import Foundation
import AVFoundation

/// Bounded disposable PCM copies. Never schedules inference on a capture callback.
/// Disabled by default; writing the durable recording always happens first.
public final class CaptionAudioFeed: @unchecked Sendable {
    public static let shared = CaptionAudioFeed()
    public struct Chunk: Sendable {
        public let samples: [Float]
        public let rate: Double
        public let source: String
    }
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var chunks: [Chunk] = []
    private var dropped = false
    public init() {}
    public func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value; generation += 1; chunks.removeAll(keepingCapacity: true); dropped = false }
    }
    public func offer(_ buffer: AVAudioPCMBuffer, source: String) {
        guard let token: Int = lock.withLock({ enabled ? generation : nil }) else { return }
        let count = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard count > 0, count <= 16384, channels > 0 else { return }
        var samples = [Float](repeating: 0, count: count)
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            for i in 0..<count { for c in 0..<channels { samples[i] += data[interleaved ? 0 : c][interleaved ? i * channels + c : i] / Float(channels) } }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<count { for c in 0..<channels { samples[i] += Float(data[interleaved ? 0 : c][interleaved ? i * channels + c : i]) / (32768 * Float(channels)) } }
        } else { return }
        lock.withLock {
            guard enabled, generation == token else { return }
            while !chunks.isEmpty && (chunks.count >= 24 || chunks.reduce(0.0, { $0 + Double($1.samples.count) / $1.rate }) + Double(count) / buffer.format.sampleRate > 2) {
                chunks.removeFirst(); dropped = true
            }
            chunks.append(Chunk(samples: samples, rate: buffer.format.sampleRate, source: source))
        }
    }
    public func drain() -> (chunks: [Chunk], dropped: Bool) {
        lock.withLock {
            let result = (chunks, dropped)
            chunks.removeAll(keepingCapacity: true); dropped = false
            return result
        }
    }
}
