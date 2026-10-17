import Testing
@testable import MinutesSpeech

struct LiveVoiceWindowQueueTests {
    @Test func busyInferenceDoesNotDiscardNextWindowAndCapacityIsExplicit() {
        var queue = LiveVoiceWindowQueue(capacity: 2)
        func window(_ id: String) -> LiveVoiceWindowQueue.Window {
            .init(id: id, samples: [0.1], rate: 16_000)
        }
        let result1 = queue.append(window("first"))
        #expect(result1)
        let result2 = queue.next()?.id == "first" // first inference is now running
        #expect(result2)
        let result3 = queue.append(window("second"))
        #expect(result3)
        let result4 = queue.append(window("third"))
        #expect(result4)
        let result5 = !queue.append(window("overflow"))
        #expect(result5)
        let result6 = queue.next()?.id == "second"
        #expect(result6)
        let result7 = queue.next()?.id == "third"
        #expect(result7)
        let result8 = queue.next() == nil
        #expect(result8)
        let result9 = queue.append(window("new-session"))
        #expect(result9)
        queue.removeAll()
        let result10 = queue.next() == nil
        #expect(result10)
    }
    @Test func invalidAndUnboundedAudioIsRejected() {
        var queue = LiveVoiceWindowQueue()
        let result11 = !queue.append(.init(id: "invalid", samples: [.nan], rate: 16_000))
        #expect(result11)
        let result12 = !queue.append(.init(id: "invalid", samples: [1], rate: .infinity))
        #expect(result12)
        let result13 = !queue.append(.init(id: "large", samples: Array(repeating: 0, count: 240_001), rate: 16_000))
        #expect(result13)
    }
}
