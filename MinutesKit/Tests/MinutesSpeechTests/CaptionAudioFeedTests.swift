import Testing
import AVFoundation
@testable import MinutesSpeech

struct CaptionAudioFeedTests {
    @Test func disabledAndBackpressure() throws {
        let feed = CaptionAudioFeed()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.25 }
        feed.offer(buffer, source: "Fixture")
        #expect(feed.drain().chunks.isEmpty)
        feed.setEnabled(true)
        for _ in 0..<100 { feed.offer(buffer, source: "Fixture") }
        let batch = feed.drain()
        #expect(batch.dropped)
        #expect(batch.chunks.count <= 20)
        #expect(batch.chunks.allSatisfy { $0.samples[0] == 0.25 })
        #expect(feed.drain().chunks.isEmpty)
        feed.offer(buffer, source: "Fixture"); feed.setEnabled(false)
        #expect(feed.drain().chunks.isEmpty)
    }
    @Test func integerStereoDownmixIsAnOwnedCopy() throws {
        let feed = CaptionAudioFeed(); feed.setEnabled(true)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        for i in 0..<4 { buffer.int16ChannelData![0][i] = i.isMultiple(of: 2) ? 16384 : 0 }
        feed.offer(buffer, source: "Microphone")
        buffer.int16ChannelData![0][0] = 0
        let batch = feed.drain()
        #expect(batch.chunks[0].samples == [0.25, 0.25])
    }
}

struct CaptionAudioFeedSourceBudgetTests {
    @Test("A backlog on one source drops only that source's audio")
    func perSourceBudget() throws {
        let feed = CaptionAudioFeed(); feed.setEnabled(true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        feed.offer(buffer, source: "Microphone")
        for _ in 0..<100 { feed.offer(buffer, source: "Mac audio") }
        let batch = feed.drain()
        #expect(batch.droppedSources == ["Mac audio"])
        #expect(batch.chunks.filter { $0.source == "Microphone" }.count == 1)
    }
}
