import Foundation

/// How confident Minutes must be before it names a speaker on its own.
/// Scores are cosine similarity against consented voiceprints, not calibrated
/// probabilities; `minutes-cli speakers calibrate` measures each preset on the
/// person's own labeled meetings.
public struct SpeakerAutoLabelPolicy: Codable, Sendable, Equatable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case cautious, balanced, eager, custom
    }

    /// When false, speakers are only ever named by the person.
    public var enabled: Bool
    public var preset: Preset
    /// Minimum similarity to the person's remembered voice.
    public var similarity: Double
    /// Minimum lead over the next most similar remembered voice.
    public var margin: Double
    /// Minimum seconds of speech in the cluster before it may be named.
    public var minimumSpeechSeconds: Double
    /// When every invitee but one is identified and exactly one confident-length
    /// voice is left, name it after the remaining invitee.
    public var nameLastInvitee: Bool

    public init(enabled: Bool, preset: Preset, similarity: Double, margin: Double,
                minimumSpeechSeconds: Double, nameLastInvitee: Bool = false) {
        self.enabled = enabled
        self.preset = preset
        self.similarity = min(0.99, max(0.5, similarity))
        self.margin = min(0.5, max(0.0, margin))
        self.minimumSpeechSeconds = max(1, minimumSpeechSeconds)
        self.nameLastInvitee = nameLastInvitee
    }

    public static func preset(_ preset: Preset, enabled: Bool = true) -> SpeakerAutoLabelPolicy {
        // Calibrated 2026-11-04 on the owner's library (minutes-cli speakers calibrate --detail):
        // same-person similarity 0.66–0.95, closest other person ≤ 0.51 (usually < 0.31).
        switch preset {
        case .cautious: SpeakerAutoLabelPolicy(enabled: enabled, preset: .cautious, similarity: 0.78, margin: 0.20, minimumSpeechSeconds: 8)
        case .balanced, .custom: SpeakerAutoLabelPolicy(enabled: enabled, preset: preset, similarity: 0.65, margin: 0.15, minimumSpeechSeconds: 5)
        case .eager: SpeakerAutoLabelPolicy(enabled: enabled, preset: .eager, similarity: 0.58, margin: 0.10, minimumSpeechSeconds: 4)
        }
    }

    /// Out of the box: name speakers automatically at the Balanced level.
    public static let `default` = preset(.balanced)

    /// The fixed rule from before this policy existed; the default for callers that pass none.
    public static let legacy = SpeakerAutoLabelPolicy(enabled: true, preset: .custom, similarity: 0.88, margin: 0.12, minimumSpeechSeconds: 5)

    public var matcher: SpeakerMatcher {
        SpeakerMatcher(autoThreshold: similarity, suggestThreshold: similarity, attendeeBonus: 0,
                       allowAutomaticAssignment: enabled, minimumMargin: margin,
                       automaticSimilarityFloor: similarity, automaticMarginFloor: margin,
                       automaticMinimumSpeechSeconds: minimumSpeechSeconds)
    }
}
