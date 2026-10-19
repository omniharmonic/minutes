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
    private var droppedSources: Set<String> = []
    public init() {}
    public func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value; generation += 1; chunks.removeAll(keepingCapacity: true); droppedSources.removeAll() }
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
            // Budget per source: a burst on one source must not evict the other's audio.
            func pending() -> (count: Int, seconds: Double) {
                chunks.reduce(into: (0, 0.0)) { total, chunk in
                    guard chunk.source == source else { return }
                    total.0 += 1; total.1 += Double(chunk.samples.count) / chunk.rate
                }
            }
            while case let budget = pending(), budget.count > 0,
                  budget.count >= 24 || budget.seconds + Double(count) / buffer.format.sampleRate > 2,
                  let oldest = chunks.firstIndex(where: { $0.source == source }) {
                chunks.remove(at: oldest); droppedSources.insert(source)
            }
            chunks.append(Chunk(samples: samples, rate: buffer.format.sampleRate, source: source))
        }
    }
    public func drain() -> (chunks: [Chunk], dropped: Bool, droppedSources: Set<String>) {
        lock.withLock {
            let result = (chunks, !droppedSources.isEmpty, droppedSources)
            chunks.removeAll(keepingCapacity: true); droppedSources.removeAll()
            return result
        }
    }
}
