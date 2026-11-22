import Foundation
import Testing
import AVFoundation
import MinutesCore
@testable import MinutesSpeech

struct SpeakerClipTests {
    private func u(_ start: Double, _ end: Double, _ cluster: String = "a", _ text: String = "Synthetic line") -> Utterance {
        Utterance(id: start.isFinite ? Int(start * 100) : 0, meetingId: "fixture", clusterId: cluster, speakerName: cluster, start: start, end: end, text: text)
    }

    private func spans(_ segments: [SpeakerClip.Segment]) -> [[Double]] { segments.map { [$0.start, $0.end] } }

    @Test func emptyOrUntimedClusterPlansNothing() {
        #expect(SpeakerClip.plan(utterances: [], clusterID: "a").isEmpty)
        #expect(SpeakerClip.plan(utterances: [u(.nan, 4), u(-1, 2), u(5, 3), u(0, .infinity), u(0, 5, "b")], clusterID: "a").isEmpty)
    }

    @Test func longestCleanUtterancesFirstThenTimeOrderWithGaps() {
        // 4 s, 3 s and 2 s clean lines; a 6 s line overlapped by speaker b.
        let utterances = [u(0, 4), u(10, 16), u(11, 12, "b"), u(20, 23), u(30, 32)]
        let plan = SpeakerClip.plan(utterances: utterances, clusterID: "a", maxSeconds: 10)
        // 4 + 0.25 + 3 + 0.25 + 2 = 9.5 s.
        // 0.25 s would be left after the next gap, too short to cut.
        #expect(spans(plan) == [[0, 4], [20, 23], [30, 32]])
        let total = plan.reduce(0) { $0 + $1.duration } + SpeakerClip.gapSeconds * Double(max(plan.count - 1, 0))
        #expect(total <= 10 + 1e-9)
        #expect(plan.map(\.start) == plan.map(\.start).sorted())
    }

    @Test func overlappedSpeechIsOnlyUsedWhenCleanSpeechRunsOut() {
        let utterances = [u(0, 8), u(1, 2, "b"), u(20, 22)]
        let plan = SpeakerClip.plan(utterances: utterances, clusterID: "a", maxSeconds: 10)
        // Clean 2 s line first, then 10 - 2 - 0.25 = 7.75 s cut from the overlapped one.
        #expect(spans(plan) == [[0, 7.75], [20, 22]])
    }

    @Test func cutsTheNextUtteranceToTheRemainingTimeAndStops() {
        let utterances = [u(0, 6, "a", "first"), u(10, 15, "a", "second"), u(20, 21, "a", "third")]
        let plan = SpeakerClip.plan(utterances: utterances, clusterID: "a", maxSeconds: 10)
        // 6 s whole, then 10 - 6 - 0.25 = 3.75 s of the 5 s line; the 1 s line is not used after a cut.
        #expect(spans(plan) == [[0, 6], [10, 13.75]])
        #expect(plan.map(\.text) == ["first", "second"])
        let single = SpeakerClip.plan(utterances: [u(5, 60)], clusterID: "a", maxSeconds: 3)
        #expect(spans(single) == [[5, 8]])
    }

    @Test func tinyRemaindersAreNotCut() {
        let plan = SpeakerClip.plan(utterances: [u(0, 9.5), u(20, 25)], clusterID: "a", maxSeconds: 10)
        #expect(spans(plan) == [[0, 9.5]]) // 0.25 s left after the gap
    }

    @Test func tiesPreferTheEarlierUtterance() {
        let plan = SpeakerClip.plan(utterances: [u(30, 34), u(0, 4), u(10, 14)], clusterID: "a", maxSeconds: 8.25)
        #expect(spans(plan) == [[0, 4], [10, 14]])
    }

    @Test func onlyCompetingClustersCountAsOverlap() {
        // b speaks on another track (separate audio file), so it does not mask a.
        let utterances = [u(0, 6), u(1, 5, "b"), u(10, 12)]
        let perTrack = SpeakerClip.plan(utterances: utterances, clusterID: "a", competingClusterIDs: ["a"], maxSeconds: 6)
        #expect(spans(perTrack) == [[0, 6]])
        let mixed = SpeakerClip.plan(utterances: utterances, clusterID: "a", maxSeconds: 6)
        #expect(spans(mixed) == [[0, 3.75], [10, 12]])
    }

    @Test func pruneDeletesOnlyFilesOlderThanSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SpeakerClip.prepareDirectory(dir)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
        let old = dir.appendingPathComponent("old.m4a"), fresh = dir.appendingPathComponent("fresh.m4a")
        try Data([1]).write(to: old); try Data([1]).write(to: fresh)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-6 * 24 * 3600)], ofItemAtPath: fresh.path)
        #expect(SpeakerClip.prune(directory: dir, now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func makeWritesAPrivateMonoAACClip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clip-make-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 20 s of 48 kHz stereo tone: the writer must downmix and resample.
        let source = root.appendingPathComponent("fixture.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let frames = AVAudioFrameCount(48000 * 20)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48000) }
        }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }

        let meeting = Meeting(id: "m", title: "Fixture", audioPath: source.path)
        let cluster = SpeakerCluster(id: "c1", meetingId: "m", trackId: "mixed", label: "Speaker 1")
        let utterances = [u(1, 5, "c1", "one"), u(8, 11, "c1", "two"), u(14, 17.5, "c1", "three")]
        let clips = root.appendingPathComponent("clips")
        let output = try SpeakerClip.make(meeting: meeting, cluster: cluster, clusters: [cluster], utterances: utterances,
                                          maxSeconds: 10, directory: clips)
        #expect(output.url.deletingLastPathComponent().lastPathComponent == "clips")
        #expect(output.url.pathExtension == "m4a")
        // 4 s and 3.5 s whole, then 2 s cut from the 3 s line: 4 + 3.5 + 2 + 2 × 0.25 = 10 s.
        #expect(spans(output.segments) == [[1, 5], [8, 10], [14, 17.5]])
        #expect(abs(output.duration - 10) < 0.01)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
        #expect(((attributes[.size] as? NSNumber)?.intValue ?? .max) < 80_000) // ~40 KB of 32 kbps audio after a ~24 KB header
        let written = try AVAudioFile(forReading: output.url)
        #expect(written.fileFormat.channelCount == 1)
        #expect(written.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(Double(written.length) / written.fileFormat.sampleRate - 10) < 0.2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasPrefix(".") }.isEmpty)
    }

    @Test func makeReportsMissingAudioAndUntimedClusters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clip-errors-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cluster = SpeakerCluster(id: "c1", meetingId: "m", trackId: "mixed", label: "Speaker 1")
        let missing = Meeting(id: "m", title: "Fixture", audioPath: root.appendingPathComponent("gone.caf").path)
        #expect(throws: SpeakerClipError.noTimedUtterances) {
            try SpeakerClip.make(meeting: missing, cluster: cluster, clusters: [cluster], utterances: [u(.nan, 1, "c1")], directory: root)
        }
        do {
            _ = try SpeakerClip.make(meeting: missing, cluster: cluster, clusters: [cluster], utterances: [u(0, 1, "c1")], directory: root)
            Issue.record("accepted a missing file")
        } catch SpeakerClipError.audioUnavailable {} catch { Issue.record("unexpected \(error)") }
    }
}
