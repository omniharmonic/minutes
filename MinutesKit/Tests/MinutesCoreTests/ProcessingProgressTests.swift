import Foundation
import Testing
@testable import MinutesCore

struct ProcessingProgressTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Double, String)] = []
        func append(_ value: Double, _ phase: String) { lock.withLock { values.append((value, phase)) } }
        var all: [(Double, String)] { lock.withLock { values } }
    }

    @Test func nestedStagesMapIntoTheirShareOfTheJob() async {
        let recorder = Recorder()
        await ProcessingProgress.tracking({ recorder.append($0, $1) }) {
            await ProcessingProgress.within(0...0.8) {
                await ProcessingProgress.within(0.2...0.98) {
                    ProcessingProgress.report(0.5, phase: "Transcribing")
                }
            }
            await ProcessingProgress.within(0.8...1) { ProcessingProgress.report(1, phase: "Writing notes") }
        }
        let values = recorder.all.map(\.0)
        #expect(abs(values[0] - 0.8 * (0.2 + 0.5 * 0.78)) < 1e-9)
        #expect(values[1] == 1)
        #expect(recorder.all.map(\.1) == ["Transcribing", "Writing notes"])
    }

    @Test func reportsOutsideATrackedJobAreIgnoredAndOutOfRangeValuesClamp() async {
        ProcessingProgress.report(0.5, phase: "Unobserved")
        let recorder = Recorder()
        await ProcessingProgress.tracking({ recorder.append($0, $1) }) {
            ProcessingProgress.report(-1, phase: "Low")
            ProcessingProgress.report(.nan, phase: "Invalid")
            ProcessingProgress.report(7, phase: "High")
        }
        #expect(recorder.all.map(\.0) == [0, 0, 1])
    }

    @Test func estimatedStagesAdvanceButNeverFinishOnTheirOwn() {
        let samples = [0.0, 10, 60, 600, 6_000].map { ProcessingProgress.estimatedFraction(elapsed: $0, expected: 120) }
        #expect(samples.first == 0)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
        #expect(samples.allSatisfy { $0 <= 0.95 })
    }
}
