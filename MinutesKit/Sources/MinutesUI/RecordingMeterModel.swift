import Foundation
import Combine

/// High-frequency capture display state, deliberately separate from app navigation.
@MainActor
public final class RecordingMeterModel: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var duration: Double
        public var level: Float?
        public var history: [Float]
    }
    @Published public private(set) var snapshot = Snapshot(duration: 0, level: 0, history: Array(repeating: 0, count: 60))
    public var duration: Double { snapshot.duration }
    public var level: Float? { snapshot.level }
    public init() {}
    public func update(duration: Double, level: Float?) {
        let duration = duration.isFinite ? max(snapshot.duration, max(0, duration)) : snapshot.duration
        let level = normalized(level)
        var next = snapshot
        if duration > snapshot.duration, let level {
            next.history.removeFirst()
            next.history.append(level)
        }
        next.duration = duration
        next.level = level
        if next != snapshot { snapshot = next }
    }
    public func reset(level: Float? = 0) {
        let next = Snapshot(duration: 0, level: normalized(level), history: Array(repeating: 0, count: 60))
        if next != snapshot { snapshot = next }
    }
    public func finish(duration: Double? = nil) {
        var next = snapshot
        if let duration, duration.isFinite { next.duration = max(0, duration) }
        if next.level != nil { next.level = 0 }
        if next != snapshot { snapshot = next }
    }
    private func normalized(_ level: Float?) -> Float? {
        level.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    }
}
