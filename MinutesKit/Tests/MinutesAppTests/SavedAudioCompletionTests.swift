import Foundation
import Testing
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor struct SavedAudioCompletionTests {
 @Test(arguments:[false,true])
 func savedAudioRetryProducesMissingSummaryAndPreservesExisting(existingSummary:Bool) async throws {
  let store=try MinutesStore(dbPath:":memory:")
  let meeting=Meeting(id:"saved",title:"My saved meeting",status:"recorded",audioPath:"/synthetic/saved.wav")
  try store.saveMeeting(meeting)
  if existingSummary {try store.saveSummary(MeetingSummary(meetingId:meeting.id,title:meeting.title,overview:"Manual",markdown:"Keep this manual summary"))}
  let state=try AppState(store:store,processAudio:{id,_,_ in
   PipelineResult(meetingId:id,audioDuration:12,sampleRate:16000,words:[],segments:[],clusters:[],utterances:[Utterance(id:1,meetingId:id,clusterId:"c",speakerName:"Speaker 1",start:0,end:12,text:"We agreed to inspect the telescope on Tuesday. Ana will compare the lens specifications and send the report on Friday.")],speechDuration:12)
  },summarizeMeeting:{meeting,_,_,_,_ in
   MeetingSummary(meetingId:meeting.id,title:meeting.title,overview:"Generated",markdown:"Recovered meeting summary")
  })
  state.selectMeeting(id:meeting.id)
  await state.processCurrentMeeting()
  #expect(store.listUtterances(meetingId:meeting.id).count==1)
  #expect(store.getSummary(meetingId:meeting.id)?.markdown == (existingSummary ? "Keep this manual summary":"Recovered meeting summary"))
  #expect(store.getMeeting(id:meeting.id)?.title=="My saved meeting")
  #expect(!state.isProcessing && !state.isSummarizing)
 }
}
