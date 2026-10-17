import Foundation

public enum CaptionSilenceGate {
    /// Skip starting another recognizer for digital silence; active requests still receive all PCM.
    public static func isQuietTail(frames: Int, lastSignal: Int, rate: Double) -> Bool {
        rate.isFinite && rate > 0 && frames >= lastSignal && Double(frames - lastSignal) / rate >= 2
    }
    public static func containsSignal(_ samples: [Float]) -> Bool {
        samples.contains { $0.isFinite && abs($0) > 0.0001 }
    }
}
