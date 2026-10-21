import Foundation

/// Rolling peak levels for the Live Activity waveform. Coarse buckets and a
/// small quantization range keep the payload tiny (well under the 4 KB
/// ActivityKit limit) and avoid updates for changes nobody could see.
public struct RecordingWaveform: Sendable, Equatable {
    public static let maximumLevel: UInt8 = 15
    public let barCount: Int
    public let bucketSeconds: Double
    public private(set) var levels: [UInt8]
    private var bucketIndex: Int?
    private var bucketPeak: Float = 0

    public init(barCount: Int = 28, bucketSeconds: Double = 0.25) {
        self.barCount = max(1, barCount)
        self.bucketSeconds = bucketSeconds.isFinite && bucketSeconds > 0 ? bucketSeconds : 0.25
        self.levels = Array(repeating: 0, count: self.barCount)
    }

    /// Maps a 0...1 display level to 0...maximumLevel. Non-finite input is silence.
    public static func quantize(_ level: Float) -> UInt8 {
        guard level.isFinite else { return 0 }
        let clamped = min(1, max(0, level))
        return UInt8((clamped * Float(maximumLevel)).rounded())
    }

    public static func normalized(_ levels: [UInt8]) -> [Double] {
        levels.map { Double(min($0, maximumLevel)) / Double(maximumLevel) }
    }

    /// Downsamples an arbitrary history (oldest first) to `bars` peak buckets.
    /// The newest samples are kept when the history is shorter than `bars`.
    public static func downsample(_ history: [Float], bars: Int) -> [UInt8] {
        let bars = max(1, bars)
        guard !history.isEmpty else { return Array(repeating: 0, count: bars) }
        guard history.count > bars else {
            return Array(repeating: 0, count: bars - history.count) + history.map(quantize)
        }
        return (0..<bars).map { bar in
            let lower = bar * history.count / bars
            let upper = max(lower + 1, (bar + 1) * history.count / bars)
            return quantize(history[lower..<upper].map { $0.isFinite ? $0 : 0 }.max() ?? 0)
        }
    }

    /// Feeds a meter sample at a recording time in seconds. Each bucket keeps
    /// its peak; skipped buckets (no samples) are silence.
    public mutating func append(level: Float, at seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let index = Int(seconds / bucketSeconds)
        let level = level.isFinite ? min(1, max(0, level)) : 0
        guard let current = bucketIndex else {
            bucketIndex = index; bucketPeak = level; publishCurrent(); return
        }
        if index == current {
            bucketPeak = max(bucketPeak, level)
            publishCurrent()
        } else if index > current {
            // Close the current bucket, then shift in silent gaps and the new one.
            let gap = min(index - current - 1, barCount)
            if gap > 0 { shift(Array(repeating: 0, count: gap)) }
            shift([0])
            bucketIndex = index; bucketPeak = level; publishCurrent()
        }
        // Older timestamps (time going backwards) are ignored.
    }

    private mutating func publishCurrent() { levels[levels.count - 1] = Self.quantize(bucketPeak) }
    private mutating func shift(_ values: [UInt8]) {
        levels.append(contentsOf: values)
        if levels.count > barCount { levels.removeFirst(levels.count - barCount) }
    }
}
