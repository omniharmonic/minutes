import Foundation
import MinutesCore
import MinutesSpeakerID

enum VoiceEnrollmentCLI {
 static func run(arguments:[String],store:MinutesStore) throws {
  guard arguments.count >= 4 else { throw VoiceEnrollmentCLIError.usage }
  if arguments[2] == "samples" {
   for sample in VoiceEnrollment.candidates(store:store,personID:arguments[3]) { print("\(sample.meeting.id) \(sample.cluster.id) \(Int(sample.cluster.speechSeconds)) seconds") };return
  }
  guard arguments[2] == "remember",arguments.count>=6,arguments.contains("--confirm") else { throw VoiceEnrollmentCLIError.usage }
  let sample=try VoiceEnrollment.remember(store:store,personID:arguments[3],meetingID:arguments[4],clusterID:arguments[5]);print("Remembered voice \(sample.id). Future recognition still uses conservative matching.")
 }
}
private enum VoiceEnrollmentCLIError:Error,LocalizedError {
 case usage
 var errorDescription:String?{"Use voices samples <person-id> or voices remember <person-id> <meeting-id> <cluster-id> --confirm [--data-dir path]. Remember only with the speaker’s consent."}
}
