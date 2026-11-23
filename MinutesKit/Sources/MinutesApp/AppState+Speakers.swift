#if canImport(SwiftUI)
import Foundation
import MinutesCore
import MinutesSpeakerID
import MinutesCalendar

/// Speaker naming for the review screen, the transcript and the control socket.
/// Store changes go through `SpeakerAssignment` (also used by `minutes-cli
/// assign`); each change then runs `speakersChanged`, which rewrites generic
/// labels in the summary and keeps the vault note current.
extension AppState {
    /// Assigns a chosen person to a speaker cluster.
    public func assignSpeaker(meetingID: String, clusterID: String, person: Person) throws {
        try changeSpeakers(meetingID: meetingID) {
            try SpeakerAssignment.assign(store: store, meetingID: meetingID, clusterID: clusterID, person: person)
        }
    }

    /// Sets the speaker name on every transcript line of a cluster.
    public func renameSpeakerUtterances(meetingID: String, clusterID: String, name: String) throws {
        try changeSpeakers(meetingID: meetingID) {
            try SpeakerAssignment.renameUtterances(store: store, meetingID: meetingID, clusterID: clusterID, name: name)
        }
    }

    /// Changes the speaker of one transcript line.
    public func renameUtteranceSpeaker(meetingID: String, utteranceID: Int, name: String) throws {
        try changeSpeakers(meetingID: meetingID) {
            try SpeakerAssignment.renameUtterance(store: store, meetingID: meetingID, utteranceID: utteranceID, name: name)
        }
    }

    /// Marks a cluster as an unknown speaker.
    public func keepSpeakerUnknown(meetingID: String, clusterID: String) throws {
        try changeSpeakers(meetingID: meetingID) {
            try SpeakerAssignment.keepUnknown(store: store, meetingID: meetingID, clusterID: clusterID)
        }
    }

    /// Names a cluster from a name and optional email (person found or created),
    /// renames its transcript lines and, with `learn`, remembers the voice.
    @discardableResult
    public func assignSpeaker(meetingID: String, clusterID: String, name: String, email: String?, learn: Bool) throws -> SpeakerAssignment.Outcome {
        var outcome: SpeakerAssignment.Outcome?
        try changeSpeakers(meetingID: meetingID) {
            outcome = try SpeakerAssignment.assign(store: store, meetingID: meetingID, clusterID: clusterID,
                displayName: name, email: email.map(NameResolver.cleanEmail).flatMap { $0.isEmpty ? nil : $0 }, learn: learn)
        }
        if outcome?.voiceprint != nil { voiceprints = store.listVoiceprints() }
        return outcome!
    }

    /// Runs one store change, refreshes the open meeting, then carries the new
    /// names into the summary and vault note. Nothing follows a failed change.
    private func changeSpeakers(meetingID: String, _ change: () throws -> Void) throws {
        let before = SpeakerAssignment.readableUtterances(store: store, meetingID: meetingID)
        try change()
        if currentMeeting?.id == meetingID {
            currentClusters = store.listSpeakerClusters(meetingId: meetingID)
            currentUtterances = TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meetingID), clusters: currentClusters)
        }
        speakersChanged(meetingID: meetingID, before: before)
    }
}
#endif
