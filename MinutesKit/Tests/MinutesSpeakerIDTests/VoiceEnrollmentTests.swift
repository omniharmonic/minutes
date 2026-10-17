import Foundation
import Testing
import MinutesCore
@testable import MinutesSpeakerID
struct VoiceEnrollmentTests {
 private func fixture() throws -> (MinutesStore,SpeakerCluster) {
  let st=try MinutesStore(dbPath:":memory:");try st.savePerson(Person(id:"p",displayName:"Fictional Ana"));try st.savePerson(Person(id:"other",displayName:"Fictional Ben"));try st.saveMeeting(Meeting(id:"m",title:"Synthetic"))
  let c=SpeakerCluster(id:"c",meetingId:"m",trackId:"t",label:"Speaker 1",centroid:[1]+Array(repeating:0,count:255),speechSeconds:25,embeddingModel:SpeakerEmbeddingModel.trainedID)
  try st.saveSpeakerClusters([c]);try st.saveUtterances([Utterance(id:1,meetingId:"m",clusterId:"c",speakerName:"Speaker 1",start:0,end:25,text:"Synthetic speech")]);return(st,c)
 }
 @Test func explicitEnrollmentUpdatesIdentityAndTranscriptAtomically() throws {
  let(st,c)=try fixture();#expect(VoiceEnrollment.candidates(store:st,personID:"p").count==1)
  try VoiceEnrollment.remember(store:st,personID:"p",meetingID:"m",clusterID:"c",expected:c)
  #expect(st.listVoiceprints().count==1);#expect(st.listUtterances(meetingId:"m").first?.speakerName=="Fictional Ana");#expect(st.listSpeakerClusters(meetingId:"m").first?.assignment=="user")
 }
 @Test func repeatedEnrollmentDoesNotDuplicateEvidence() throws {
  let(st,_)=try fixture()
  let first=try VoiceEnrollment.remember(store:st,personID:"p",meetingID:"m",clusterID:"c")
  let second=try VoiceEnrollment.remember(store:st,personID:"p",meetingID:"m",clusterID:"c")
  #expect(first.id == second.id);#expect(st.listVoiceprints().count == 1)
 }
 @Test(arguments:["short","old","nan","other","changed"])
 func refusesUnusableForeignAndStaleSamples(kind:String) throws {
  let(st,c)=try fixture();var edited=c
  switch kind {case "short":edited.speechSeconds=19;case "old":edited.embeddingModel="legacy";case "nan":edited.centroid[0] = .nan;case "other":edited.personId="other";default:edited.centroid=[0,1]+Array(repeating:0,count:254)}
  try st.saveSpeakerClusters([edited])
  #expect(throws:(any Error).self){try VoiceEnrollment.remember(store:st,personID:"p",meetingID:"m",clusterID:"c",expected:kind=="changed" ? c:nil)}
  #expect(st.listVoiceprints().isEmpty);#expect(st.listUtterances(meetingId:"m").first?.speakerName=="Speaker 1")
 }
}
