import Foundation

/// Carries speaker names chosen after a summary was written into that summary,
/// so it reads "Ana proposed…" rather than "Speaker 2 proposed…".
/// Only generic labels are replaced; a real name is never rewritten into another.
public enum SummarySpeakerNames {
    /// Labels Minutes invents before anyone is named.
    public static func isGeneric(_ label: String) -> Bool {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "Unknown speaker" || value.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// Generic label → new name, from the readable transcript before and after a
    /// speaker change. A label shown for several voices that now differ is skipped.
    public static func renames(before: [Utterance], after: [Utterance]) -> [String: String] {
        func names(_ utterances: [Utterance]) -> [String: String] {
            utterances.reduce(into: [:]) { $0[$1.clusterId] = $0[$1.clusterId] ?? $1.speakerName.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let old = names(before), new = names(after)
        var candidates: [String: Set<String>] = [:]
        for (cluster, from) in old {
            guard let to = new[cluster], isGeneric(from), !to.isEmpty, !isGeneric(to), from != to else { continue }
            candidates[from, default: []].insert(to)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// The summary with every whole-word occurrence of each generic label
    /// replaced, or nil when nothing changed.
    public static func apply(_ renames: [String: String], to summary: MeetingSummary) -> MeetingSummary? {
        let usable = renames.filter { isGeneric($0.key) && !$0.value.isEmpty }
        guard !usable.isEmpty,
              let data = try? JSONEncoder().encode(summary),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rewritten = rewrite(object, usable)
        guard let output = try? JSONSerialization.data(withJSONObject: rewritten),
              let updated = try? JSONDecoder().decode(MeetingSummary.self, from: output),
              let before = try? JSONEncoder().encode(summary), let after = try? JSONEncoder().encode(updated),
              before != after else { return nil }
        return updated
    }

    static func replace(_ text: String, _ renames: [String: String]) -> String {
        var result = text
        // Longest first so "Speaker 12" is handled before "Speaker 1".
        for (from, to) in renames.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }

    private static func rewrite(_ value: Any, _ renames: [String: String]) -> Any {
        switch value {
        case let text as String: return replace(text, renames)
        case let array as [Any]: return array.map { rewrite($0, renames) }
        case let object as [String: Any]:
            // Identifiers are not prose.
            return object.reduce(into: [String: Any]()) { result, item in
                result[item.key] = item.key == "meetingId" || item.key == "id" ? item.value : rewrite(item.value, renames)
            }
        default: return value
        }
    }
}
