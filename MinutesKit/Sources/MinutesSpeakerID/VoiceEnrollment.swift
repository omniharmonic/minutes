import Foundation
import MinutesCore

public struct VoiceEnrollmentCandidate: Identifiable, Sendable {
 public let meeting: Meeting
 public let cluster: SpeakerCluster
 public var id: String { meeting.id + ":" + cluster.id }
}
public enum VoiceEnrollmentError: Error, LocalizedError {
 case missingPerson, missingSample, unusableSample, changedSample, belongsToAnotherPerson
 public var errorDescription: String? {
  switch self {
  case .missingPerson: "This person no longer exists."
  case .missingSample: "This speaker sample no longer exists."
  case .unusableSample: "Choose a current voice sample with at least 20 seconds of usable speech."
  case .changedSample: "This recording was processed again. Review its updated speakers before remembering this voice."
  case .belongsToAnotherPerson: "This speaker is assigned to another person. Review that assignment in the meeting first."
  }
 }
}
public enum VoiceEnrollment {
 public static func isEligible(_ cluster: SpeakerCluster) -> Bool {
  cluster.embeddingModel == SpeakerEmbeddingModel.trainedID && cluster.centroid.count == 256 &&
  cluster.centroid.allSatisfy(\.isFinite) && VectorMath.l2Norm(cluster.centroid) > 1e-12 &&
  cluster.speechSeconds.isFinite && cluster.speechSeconds >= 20
 }
 public static func candidates(store: MinutesStore, personID: String) -> [VoiceEnrollmentCandidate] {
  store.listMeetings().flatMap { meeting in
   store.listSpeakerClusters(meetingId: meeting.id).filter { isEligible($0) && ($0.personId == nil || $0.personId == personID) }
    .map { VoiceEnrollmentCandidate(meeting: meeting, cluster: $0) }
  }
 }
 @discardableResult public static func remember(store: MinutesStore, personID: String, meetingID: String, clusterID: String, expected: SpeakerCluster? = nil) throws -> Voiceprint {
  var enrolled: Voiceprint?
  try store.withImmediateTransaction {
   guard let person = store.getPerson(id: personID) else { throw VoiceEnrollmentError.missingPerson }
   guard var cluster = store.listSpeakerClusters(meetingId: meetingID).first(where: { $0.id == clusterID }) else { throw VoiceEnrollmentError.missingSample }
   if let expected, expected.meetingId != cluster.meetingId || expected.embeddingModel != cluster.embeddingModel || expected.centroid != cluster.centroid || expected.speechSeconds != cluster.speechSeconds || expected.personId != cluster.personId || expected.assignment != cluster.assignment { throw VoiceEnrollmentError.changedSample }
   guard cluster.personId == nil || cluster.personId == personID else { throw VoiceEnrollmentError.belongsToAnotherPerson }
   guard isEligible(cluster) else { throw VoiceEnrollmentError.unusableSample }
   cluster.personId=personID;cluster.label=person.displayName;cluster.assignment="user"
   try store.saveSpeakerClusters([cluster])
   var utterances=store.listUtterances(meetingId:meetingID)
   for index in utterances.indices where utterances[index].clusterId == clusterID { utterances[index].speakerName=person.displayName }
   try store.saveUtterances(utterances)
   if let existing = store.listVoiceprints().first(where: { $0.personId == personID && $0.model == SpeakerEmbeddingModel.trainedID && $0.vector == VectorMath.l2Normalize(cluster.centroid) && $0.speechSeconds == cluster.speechSeconds }) { enrolled=existing;return }
   let voice=Voiceprint(personId:personID,model:SpeakerEmbeddingModel.trainedID,vector:VectorMath.l2Normalize(cluster.centroid),speechSeconds:cluster.speechSeconds)
   try store.saveVoiceprint(voice);enrolled=voice
  }
  guard let enrolled else { throw VoiceEnrollmentError.missingSample };return enrolled
 }
}
