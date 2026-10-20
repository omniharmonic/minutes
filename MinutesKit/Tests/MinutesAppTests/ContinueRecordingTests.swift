import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor struct ContinueRecordingTests {
    private func tone(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!; buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(0.1 * sin(Double(i) * 0.05)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    }

    @Test("Recordings join end to end and report where each part starts")
    func join() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-join-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.wav"), second = root.appendingPathComponent("b.wav")
        try tone(first, seconds: 2); try tone(second, seconds: 1)
        let joined = root.appendingPathComponent("joined.m4a")
        let offsets = try AudioStorage.join([first, second], to: joined)
        #expect(offsets.count == 2 && offsets[0] == 0 && abs(offsets[1] - 2) < 0.01)
        let file = try AVAudioFile(forReading: joined)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3) < 0.1)
    }

    @Test("Continue Recording appends to the same meeting, moves its moments and reprocesses it")
    func continueMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-continue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var parts = 0
        let store = try MinutesStore(dbPath: root.appendingPathComponent("db").path)
        let state = try AppState(store: store, audioDirectory: root, preferences: UserDefaults(suiteName: "minutes-continue-" + UUID().uuidString)!,
            recordingModelReadiness: { (true, "Ready") }, recordingEnvironmentPreflight: {},
            captureStart: { _ in }, captureStop: {
                parts += 1
                let url = root.appendingPathComponent("part\(parts).wav")
                try self.tone(url, seconds: parts == 1 ? 2 : 1)
                return url
            },
            processAudio: { id, url, _ in
                let file = try AVAudioFile(forReading: url)
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                return PipelineResult(meetingId: id, audioDuration: seconds, sampleRate: 16000, words: [], segments: [], clusters: [],
                    utterances: [Utterance(id: 1, meetingId: id, clusterId: "", speakerName: "Unknown", start: 0, end: seconds, text: "Length \(Int(seconds.rounded()))")],
                    speechDuration: seconds)
            }, summarizeMeeting: { meeting, _, _, _, _ in MeetingSummary(meetingId: meeting.id, title: meeting.title, overview: "", markdown: "") })
        state.recordingConsentAcknowledged = true
        state.startQuickMeeting()
        let original = try #require(state.activeRecordingMeetingID)
        await state.stopAndProcessMeeting()
        for _ in 0..<300 where state.compactingMeetingIDs.contains(original) || store.getMeeting(id: original)?.audioPath?.hasSuffix(".m4a") != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        let meeting = try #require(store.getMeeting(id: original))
        #expect(state.canContinueRecording(meeting))

        await state.continueRecording(meetingID: original)
        let part = try #require(state.activeRecordingMeetingID)
        #expect(part != original)
        state.recordingMeter.update(duration: 0.5, level: 0.1)
        _ = state.markRecordingMoment(label: "After the break")
        await state.stopAndProcessMeeting()

        #expect(store.getMeeting(id: part) == nil)
        #expect(store.listMeetings().filter { $0.id == original }.count == 1)
        let continued = try #require(store.getMeeting(id: original))
        #expect(continued.audioPath?.hasSuffix("joined.m4a") == true)
        #expect(store.listUtterances(meetingId: original).first?.text == "Length 3")
        let moment = try #require(store.listBookmarks(meetingId: original).first)
        #expect(moment.label == "After the break" && abs(moment.timestamp - 2.5) < 0.1)
    }
}
