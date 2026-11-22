import Foundation
import MinutesCore

public enum SpeakerAssignmentError: Error, LocalizedError, Equatable {
    case meetingNotFound(String)
    case clusterNotFound(String)
    case utteranceNotFound(Int)
    case emptyName
    case cannotLearn

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) was not found."
        case .clusterNotFound(let id): "Speaker \(id) was not found in this meeting."
        case .utteranceNotFound(let id): "Transcript line \(id) was not found in this meeting."
        case .emptyName: "A speaker name is required."
        case .cannotLearn: "Cannot learn from this speaker: it needs the trained embedding model and at least 20 seconds of usable speech. Assign without learning, or reprocess the meeting first."
        }
    }
}

/// Store-level speaker naming shared by the app (UI and control socket) and
/// `minutes-cli assign`. Callers own any presentation refresh and the
/// follow-up summary/vault update.
public enum SpeakerAssignment {
    public struct Outcome: Sendable {
        public let cluster: SpeakerCluster
        public let person: Person
        public let voiceprint: Voiceprint?
    }

    /// Finds a person by email (when given) or display name, or creates one.
    /// `email` must already be cleaned (lowercased, no `mailto:`).
    public static func resolvePerson(store: MinutesStore, displayName: String, email: String?) throws -> Person {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !name.isEmpty else { throw SpeakerAssignmentError.emptyName }
        let existing = store.listPeople().first { person in
            email.isEmpty ? person.displayName.lowercased() == name.lowercased()
                : person.emails.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email }
        }
        if let existing { return existing }
        let person = Person(displayName: name, emails: email.isEmpty ? [] : [email])
        try store.savePerson(person)
        return person
    }

    /// Assigns `person` to one cluster (label, person, `user` assignment) and saves the person.
    @discardableResult
    public static func assign(store: MinutesStore, meetingID: String, clusterID: String, person: Person) throws -> SpeakerCluster {
        var clusters = store.listSpeakerClusters(meetingId: meetingID)
        guard let index = clusters.firstIndex(where: { $0.id == clusterID }) else { throw SpeakerAssignmentError.clusterNotFound(clusterID) }
        clusters[index].label = person.displayName
        clusters[index].personId = person.id
        clusters[index].assignment = "user"
        try store.withTransaction {
            try store.savePerson(person)
            try store.saveSpeakerClusters([clusters[index]])
        }
        return clusters[index]
    }

    /// The cluster has no known person: generic label, no confidence.
    @discardableResult
    public static func keepUnknown(store: MinutesStore, meetingID: String, clusterID: String) throws -> SpeakerCluster {
        var clusters = store.listSpeakerClusters(meetingId: meetingID)
        guard let index = clusters.firstIndex(where: { $0.id == clusterID }) else { throw SpeakerAssignmentError.clusterNotFound(clusterID) }
        clusters[index].label = "Unknown speaker"
        clusters[index].personId = nil
        clusters[index].assignment = "unknown"
        clusters[index].confidence = 0
        try store.withTransaction {
            try store.saveSpeakerClusters([clusters[index]])
            try renameUtterances(store: store, meetingID: meetingID, clusterID: clusterID, name: "Unknown speaker")
        }
        return clusters[index]
    }

    /// Sets the speaker name on every utterance of one cluster. The whole
    /// transcript is saved in its readable form, as the review screen does.
    public static func renameUtterances(store: MinutesStore, meetingID: String, clusterID: String, name: String) throws {
        var utterances = readableUtterances(store: store, meetingID: meetingID)
        for index in utterances.indices where utterances[index].clusterId == clusterID { utterances[index].speakerName = name }
        try store.saveUtterances(utterances)
    }

    /// Renames the speaker of a single transcript line.
    public static func renameUtterance(store: MinutesStore, meetingID: String, utteranceID: Int, name: String) throws {
        var utterances = readableUtterances(store: store, meetingID: meetingID)
        guard let index = utterances.firstIndex(where: { $0.id == utteranceID }) else { throw SpeakerAssignmentError.utteranceNotFound(utteranceID) }
        utterances[index].speakerName = name
        try store.saveUtterances([utterances[index]])
    }

    /// The transcript as people see it (display labels repaired).
    public static func readableUtterances(store: MinutesStore, meetingID: String) -> [Utterance] {
        TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meetingID), clusters: store.listSpeakerClusters(meetingId: meetingID))
    }

    /// Names a speaker by name/email in one step: finds or creates the person,
    /// assigns the cluster, renames its utterances and, when `learn` is set,
    /// remembers the voice. Learning is checked first, so an ineligible
    /// cluster changes nothing.
    @discardableResult
    public static func assign(store: MinutesStore, meetingID: String, clusterID: String,
                              displayName: String, email: String?, learn: Bool) throws -> Outcome {
        guard store.getMeeting(id: meetingID) != nil else { throw SpeakerAssignmentError.meetingNotFound(meetingID) }
        guard let original = store.listSpeakerClusters(meetingId: meetingID).first(where: { $0.id == clusterID }) else {
            throw SpeakerAssignmentError.clusterNotFound(clusterID)
        }
        if learn && !VoiceEnrollment.isEligible(original) { throw SpeakerAssignmentError.cannotLearn }
        var outcome: Outcome?
        try store.withImmediateTransaction {
            let person = try resolvePerson(store: store, displayName: displayName, email: email)
            var cluster = try assign(store: store, meetingID: meetingID, clusterID: clusterID, person: person)
            try renameUtterances(store: store, meetingID: meetingID, clusterID: clusterID, name: person.displayName)
            var voiceprint: Voiceprint?
            if learn {
                voiceprint = try VoiceEnrollment.remember(store: store, personID: person.id, meetingID: meetingID, clusterID: clusterID)
                cluster = store.listSpeakerClusters(meetingId: meetingID).first { $0.id == clusterID } ?? cluster
            }
            outcome = Outcome(cluster: cluster, person: person, voiceprint: voiceprint)
        }
        guard let outcome else { throw SpeakerAssignmentError.clusterNotFound(clusterID) }
        return outcome
    }
}
