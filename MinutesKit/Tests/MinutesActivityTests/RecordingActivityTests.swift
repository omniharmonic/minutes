import Foundation
import Testing
@testable import MinutesActivity

struct RecordingWaveformTests {
    @Test func quantizesAndClampsLevels() {
        #expect(RecordingWaveform.quantize(0) == 0)
        #expect(RecordingWaveform.quantize(1) == RecordingWaveform.maximumLevel)
        #expect(RecordingWaveform.quantize(2) == RecordingWaveform.maximumLevel)
        #expect(RecordingWaveform.quantize(-1) == 0)
        #expect(RecordingWaveform.quantize(.nan) == 0)
        #expect(RecordingWaveform.quantize(.infinity) == 0)
        #expect(RecordingWaveform.normalized([0, 15, 200]) == [0, 1, 1])
    }

    @Test func downsampleKeepsPeaksAndPadsShortHistory() {
        let history: [Float] = (0..<60).map { $0 == 31 ? 1 : 0.2 }
        let bars = RecordingWaveform.downsample(history, bars: 30)
        #expect(bars.count == 30)
        #expect(bars[15] == 15)
        #expect(bars.filter { $0 == 15 }.count == 1)
        #expect(RecordingWaveform.downsample([1, 1], bars: 4) == [0, 0, 15, 15])
        #expect(RecordingWaveform.downsample([], bars: 3) == [0, 0, 0])
    }

    @Test func rollingBucketsShiftOldestOut() {
        var waveform = RecordingWaveform(barCount: 4, bucketSeconds: 0.25)
        waveform.append(level: 0.2, at: 0.0)
        waveform.append(level: 1.0, at: 0.1)   // same bucket keeps the peak
        #expect(waveform.levels == [0, 0, 0, 15])
        waveform.append(level: 0.0, at: 0.3)
        #expect(waveform.levels == [0, 0, 15, 0])
        waveform.append(level: 1.0, at: 0.8)   // one silent bucket skipped
        #expect(waveform.levels == [15, 0, 0, 15])
        waveform.append(level: 0.5, at: 0.2)   // time going backwards is ignored
        #expect(waveform.levels == [15, 0, 0, 15])
        waveform.append(level: 1.0, at: 100)   // long gap clears the history
        #expect(waveform.levels == [0, 0, 0, 15])
    }

    @Test func payloadStaysFarBelowActivityLimit() throws {
        var composer = RecordingActivityComposer(startedAt: Date(timeIntervalSince1970: 0))
        for tick in 0..<400 { composer.record(level: Float(tick % 10) / 10, duration: Double(tick) * 0.05) }
        let state = composer.state(phase: .recording, title: String(repeating: "Quarterly planning ", count: 20),
                                   duration: 20, caption: String(repeating: "word ", count: 400), now: Date(timeIntervalSince1970: 20))
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 1024)
        #expect(state.levels.count == 28)
        #expect(state.title.count <= 80)
    }
}

struct RecordingActivityCaptionTests {
    @Test func shortCaptionsAreCollapsedNotCut() {
        #expect(RecordingActivityCaption.truncate("  Hello \n  world  ") == "Hello world")
        #expect(RecordingActivityCaption.truncate("   ") == nil)
        #expect(RecordingActivityCaption.truncate(nil) == nil)
    }

    @Test func longCaptionsKeepNewestWordsWithinLimit() throws {
        let words = (1...80).map { "word\($0)" }.joined(separator: " ")
        let caption = try #require(RecordingActivityCaption.truncate(words, limit: 120))
        #expect(caption.count <= 120)
        #expect(caption.hasPrefix("…"))
        #expect(caption.hasSuffix("word80"))
        // Cut on a word boundary: the first visible token is a whole word.
        let first = caption.dropFirst().split(separator: " ").first.map(String.init)
        #expect(first.map { words.split(separator: " ").map(String.init).contains($0) } == true)
    }

    @Test func singleHugeWordStillFits() throws {
        let caption = try #require(RecordingActivityCaption.truncate(String(repeating: "x", count: 500)))
        #expect(caption.count == RecordingActivityCaption.defaultLimit)
    }
}

struct RecordingActivityThrottleTests {
    typealias State = RecordingActivityAttributes.ContentState
    let start = Date(timeIntervalSince1970: 1_000)
    func state(_ phase: State.Phase = .recording, title: String = "Standup", levels: [UInt8] = [1], caption: String? = nil) -> State {
        State(phase: phase, title: title, startedAt: start, levels: levels, caption: caption)
    }

    @Test func firstUpdateAlwaysSends() {
        #expect(RecordingActivityThrottle().shouldSend(state(), now: start))
    }

    @Test func unchangedStateNeverSends() {
        var throttle = RecordingActivityThrottle()
        throttle.markSent(state(), at: start)
        #expect(!throttle.shouldSend(state(), now: start.addingTimeInterval(60)))
    }

    @Test func visibleChangesWaitForInterval() {
        var throttle = RecordingActivityThrottle(minimumInterval: 1)
        throttle.markSent(state(), at: start)
        #expect(!throttle.shouldSend(state(levels: [9]), now: start.addingTimeInterval(0.5)))
        #expect(!throttle.shouldSend(state(caption: "hi"), now: start.addingTimeInterval(0.99)))
        #expect(throttle.shouldSend(state(levels: [9]), now: start.addingTimeInterval(1)))
    }

    @Test func phaseAndTitleChangesSendImmediately() {
        var throttle = RecordingActivityThrottle()
        throttle.markSent(state(), at: start)
        #expect(throttle.shouldSend(state(.saving), now: start.addingTimeInterval(0.1)))
        #expect(throttle.shouldSend(state(title: "Design review"), now: start.addingTimeInterval(0.1)))
    }

    @Test func composerThrottlesMeterTicksToAboutOncePerSecond() {
        var composer = RecordingActivityComposer(startedAt: start)
        var sent = 0
        for tick in 0..<200 { // 10 s of 20 Hz meter ticks with constantly changing levels
            let duration = Double(tick) * 0.05
            composer.record(level: Float(tick % 7) / 7, duration: duration)
            if composer.next(phase: .recording, title: "Standup", duration: duration, caption: nil,
                             now: start.addingTimeInterval(duration)) != nil { sent += 1 }
        }
        #expect(sent >= 9 && sent <= 11)
    }

    @Test func composerKeepsTimerAnchorUnlessItDrifts() throws {
        var composer = RecordingActivityComposer(startedAt: start)
        let first = composer.next(phase: .recording, title: "A", duration: 5, caption: nil, now: start.addingTimeInterval(5.5))
        let steady = try #require(first)
        #expect(steady.startedAt == start)
        let second = composer.next(phase: .saving, title: "A", duration: 5, caption: nil, now: start.addingTimeInterval(30))
        let drifted = try #require(second)
        #expect(drifted.startedAt == start.addingTimeInterval(25))
        #expect(drifted.frozenElapsed == 5)
        #expect(drifted.levels.allSatisfy { $0 == 0 })
    }
}
