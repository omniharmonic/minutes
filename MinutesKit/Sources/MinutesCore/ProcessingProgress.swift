import Foundation

/// Progress for one processing job, carried in task-local storage so stages
/// report without threading a callback through every signature. Each stage
/// reports a fraction of its own work; `within` maps it into the caller's span.
public enum ProcessingProgress {
    /// Receives overall progress in 0...1 and a short user-facing phase.
    public typealias Handler = @Sendable (_ fraction: Double, _ phase: String) -> Void

    @TaskLocal public static var handler: Handler?
    @TaskLocal static var span: ClosedRange<Double> = 0...1

    /// Reports `fraction` (0...1) of the current stage.
    public static func report(_ fraction: Double, phase: String) {
        guard let handler else { return }
        handler(overall(fraction, in: span), phase)
    }

    /// Runs `operation` as the sub-range `range` (0...1) of the current stage.
    public static func within<T>(_ range: ClosedRange<Double>, isolation: isolated (any Actor)? = #isolation,
                                 _ operation: () async throws -> T) async rethrows -> T {
        try await $span.withValue(nested(range, in: span), operation: operation)
    }

    /// Runs `operation` with `handler` receiving its progress.
    public static func tracking<T>(_ handler: @escaping Handler, isolation: isolated (any Actor)? = #isolation,
                                   _ operation: () async throws -> T) async rethrows -> T {
        try await $handler.withValue(handler) { try await $span.withValue(0...1, operation: operation) }
    }

    /// For a stage that reports nothing itself: advances toward (never reaching)
    /// its end on a time estimate, so the job never looks stalled.
    public static func estimating<T>(expectedSeconds: Double, phase: String, isolation: isolated (any Actor)? = #isolation,
                                     _ operation: () async throws -> T) async rethrows -> T {
        report(0, phase: phase)
        let pulse = Task {
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let elapsed = Double((ContinuousClock.now - start).components.seconds)
                report(estimatedFraction(elapsed: elapsed, expected: expectedSeconds), phase: phase)
            }
        }
        defer { pulse.cancel() }
        return try await operation()
    }

    static func estimatedFraction(elapsed: Double, expected: Double) -> Double {
        0.95 * (1 - exp(-max(0, elapsed) / max(1, expected)))
    }

    static func overall(_ fraction: Double, in span: ClosedRange<Double>) -> Double {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return span.lowerBound + clamped * (span.upperBound - span.lowerBound)
    }

    static func nested(_ range: ClosedRange<Double>, in span: ClosedRange<Double>) -> ClosedRange<Double> {
        overall(range.lowerBound, in: span)...overall(range.upperBound, in: span)
    }
}
