import Foundation

/// Bounded owned PCM pending local inference. No microphone, persistence or identity decisions.
public struct LiveVoiceWindowQueue: Sendable {
    public struct Window: Sendable {
        public let id: String
        public let samples: [Float]
        public let rate: Double
        public init(id: String, samples: [Float], rate: Double) {
            self.id = id; self.samples = samples; self.rate = rate
        }
    }
    private var pending: [Window] = []
    public let capacity: Int
    public init(capacity: Int = 4) { self.capacity = max(1, capacity) }
    /// False means rejected/overflow: callers must communicate incomplete matching.
    public mutating func append(_ window: Window) -> Bool {
        guard window.rate.isFinite, window.rate >= 8_000, window.rate <= 192_000,
              !window.samples.isEmpty, window.samples.count <= Int(window.rate * 15),
              window.samples.allSatisfy(\.isFinite) else { return false }
        guard pending.count < capacity else { return false }
        pending.append(window)
        return true
    }
    public mutating func next() -> Window? { pending.isEmpty ? nil : pending.removeFirst() }
    public mutating func removeAll() { pending.removeAll() }
}
