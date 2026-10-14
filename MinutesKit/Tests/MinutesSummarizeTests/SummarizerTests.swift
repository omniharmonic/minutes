import Testing
import Foundation
@testable import MinutesCore
@testable import MinutesSummarize

@Suite("MinutesSummarize Tests")
struct SummarizerTests {
    
    @Test("Summarizer extracts decisions and action items from transcript text")
    func testStructuredSummaryExtraction() async throws {
        let m = Meeting(id: "m_test", title: "Quarterly Roadmap", status: "needs_review")
        let p1 = Person(id: "p1", displayName: "Benjamin Life")
        let p2 = Person(id: "p2", displayName: "Alex Rivers")
        
        let u1 = Utterance(
            id: 1,
            meetingId: m.id,
            clusterId: "c1",
            speakerName: "Benjamin Life",
            start: 0.0,
            end: 10.0,
            text: "We agreed to migrate the entire system to Swift 6."
        )
        let u2 = Utterance(
            id: 2,
            meetingId: m.id,
            clusterId: "c2",
            speakerName: "Alex Rivers",
            start: 11.0,
            end: 20.0,
            text: "I will finalize the Parachute vault API integration by Friday."
        )
        let u3 = Utterance(
            id: 3,
            meetingId: m.id,
            clusterId: "c1",
            speakerName: "Benjamin Life",
            start: 21.0,
            end: 30.0,
            text: "What about the CoreML Parakeet models?"
        )
        
        let summarizer = Summarizer()
        let summary = try await summarizer.summarize(meeting: m, utterances: [u1, u2, u3], attendees: [p1, p2])
        
        #expect(summary.meetingId == m.id)
        #expect(!summary.decisions.isEmpty)
        #expect(summary.decisions.contains(where: { $0.contains("agreed to migrate") }))
        
        #expect(!summary.actionItems.isEmpty)
        #expect(summary.actionItems.contains(where: { $0.text.contains("finalize the Parachute") }))
        #expect(summary.actionItems.first?.owner == "Alex Rivers")
        
        #expect(!summary.questions.isEmpty)
        #expect(summary.questions.contains(where: { $0.contains("CoreML Parakeet") }))
        
        #expect(!summary.markdown.isEmpty)
        #expect(summary.markdown.contains("# Quarterly Roadmap"))
        #expect(summary.markdown.contains("[[Benjamin Life]]"))
    }
}
