import Foundation
import Testing
import MinutesCore
import MinutesSummarize

@Suite("Grounded meeting notes")
struct GroundedNotesTests {
 @Test("Extractive notes do not invent discussion topics or assign someone else's work")
 func noInventedNarrative() async throws {
  let meeting=Meeting(id:"garden",title:"Gardening")
  let speech=Utterance(id:1,meetingId:meeting.id,clusterId:"c",speakerName:"Ana",start:0,end:4,text:"Tomatoes need more water. You should call the gardener.")
  let notes=try await Summarizer().summarize(meeting:meeting,utterances:[speech],attendees:[])
  #expect(notes.overview.contains("Tomatoes need more water"))
  #expect(!notes.markdown.contains("architectural requirements"))
  #expect(!notes.topics.contains(where:{$0.title.contains("Architecture") || $0.title.contains("Project Scope")}))
  #expect(notes.actionItems.first?.owner==nil)
 }
}
