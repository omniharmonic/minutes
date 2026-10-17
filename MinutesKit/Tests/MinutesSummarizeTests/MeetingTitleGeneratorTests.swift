import Foundation
import Testing
import MinutesCore
import MinutesSummarize

@Suite("Grounded local meeting titles")
struct MeetingTitleGeneratorTests {
    private func speech(_ text: String, id: Int = 1) -> Utterance {
        Utterance(id: id, meetingId: "title", clusterId: "c", speakerName: "Speaker 1", start: Double(id), end: Double(id + 1), text: text)
    }
    @Test("Repeated substantive topic outranks opening introductions")
    func substantiveTopic() throws {
        let transcript = [speech("Hello everyone, thanks for joining this meeting. This is speaker one."),
                          speech("Geothermal heat pumps need a cost estimate. The geothermal heat pumps could replace the old heating system.", id: 2),
                          speech("Let us compare the installation costs for geothermal heat pumps before choosing a supplier.", id: 3)]
        let title = try #require(MeetingTitleGenerator.suggest(from: transcript))
        // Lexical-class boundaries can differ between system releases; assert
        // the substantive topic rather than an exact POS-dependent noun span.
        #expect(title.localizedCaseInsensitiveContains("geothermal"))
        #expect(title.localizedCaseInsensitiveContains("heat"))
        #expect(!title.localizedCaseInsensitiveContains("speaker"))
        #expect(!title.localizedCaseInsensitiveContains("hello"))
        #expect(title.count <= 65)
    }
    @Test("Blank and conversational filler cannot supply a topic")
    func insufficientEvidence() {
        #expect(MeetingTitleGenerator.suggest(from: []) == nil)
        #expect(MeetingTitleGenerator.suggest(from: [speech(" \n\t")]) == nil)
        #expect(MeetingTitleGenerator.suggest(from: [speech("Hello. Thank you. Yes, okay. This is speaker one.")]) == nil)
    }
    @Test("Extracted topic preserves source spelling and proper-name case")
    func sourceWording() throws {
        let text = "Lake Victoria water quality needs careful monitoring. We reviewed Lake Victoria water quality measurements. Lake Victoria water quality remains the main research topic."
        let title = try #require(MeetingTitleGenerator.suggest(from: [speech(text)]))
        #expect(title.contains("Lake Victoria"))
        #expect(text.contains(title))
        #expect(title.count <= 65)
        #expect(title != text)
    }
    @Test("Long topic phrases remain bounded at whole-word boundaries")
    func boundedTitle() throws {
        let text = "The regional renewable energy infrastructure modernization investment assessment needs review. The regional renewable energy infrastructure modernization investment assessment needs revised estimates."
        let title = try #require(MeetingTitleGenerator.suggest(from: [speech(text)]))
        #expect(title.count <= 65)
        #expect(title.split(separator: " ").count >= 2)
        #expect(text.contains(title))
        #expect(!title.hasSuffix("…"))
    }
    @Test("Equivalent input produces the same suggestion")
    func deterministic() {
        let transcript = [speech("Coastal erosion measurements require a survey. Coastal erosion measurements changed after the storm.")]
        #expect(MeetingTitleGenerator.suggest(from: transcript) == MeetingTitleGenerator.suggest(from: transcript))
    }
}
