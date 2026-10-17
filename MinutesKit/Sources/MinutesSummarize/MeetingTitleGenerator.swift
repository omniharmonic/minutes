import Foundation
import NaturalLanguage
import MinutesCore

/// A grounded topic label, not a generated claim. Candidates are contiguous noun
/// phrases copied from the transcript; recurrence across the whole conversation
/// outranks introductions. No model assets, network, or calendar data are used.
public enum MeetingTitleGenerator {
    private struct Token {
        let range: Range<String.Index>
        let key: String
        let isNoun: Bool
    }
    private struct Candidate {
        let text: String
        let keys: [String]
        let order: Int
        var occurrences: Int
    }
    private static let conversationalWords: Set<String> = [
        "hello", "hi", "hey", "thanks", "thank", "welcome", "yes", "no", "okay", "ok",
        "everyone", "everybody", "anyone", "anybody", "someone", "somebody",
        "speaker", "speakers", "meeting", "meetings", "conversation", "discussion",
        "thing", "things", "stuff", "something", "anything", "nothing",
        "morning", "afternoon", "evening", "today", "tomorrow", "yesterday"
    ]
    public static func suggest(from utterances: [Utterance]) -> String? {
        var candidates: [String: Candidate] = [:]
        var frequency: [String: Int] = [:]
        var order = 0
        for utterance in utterances {
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
            tagger.string = text
            var run: [Token] = []
            func collect() {
                defer { run.removeAll(keepingCapacity: true) }
                guard run.count >= 2 else { return }
                for start in run.indices {
                    for end in start..<min(run.count, start + 9) where end > start && run[end].isNoun {
                        let range = run[start].range.lowerBound..<run[end].range.upperBound
                        let phrase = text[range].components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                        guard phrase.count <= 65, phrase.count >= 8 else { continue }
                        let keys = run[start...end].map(\.key)
                        let key = keys.joined(separator: " ")
                        if var existing = candidates[key] {
                            existing.occurrences += 1; candidates[key] = existing
                        } else {
                            candidates[key] = Candidate(text: phrase, keys: keys, order: order, occurrences: 1)
                            order += 1
                        }
                    }
                }
            }
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .nameTypeOrLexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                let word = String(text[range])
                let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let isNoun = tag == .noun || tag == .personalName || tag == .placeName || tag == .organizationName
                let isNumberInPhrase = tag == .number && !run.isEmpty
                let eligible = isNoun || tag == .adjective || isNumberInPhrase
                if let last = run.last,
                   !text[last.range.upperBound..<range.lowerBound].allSatisfy(\.isWhitespace) { collect() }
                if eligible && !conversationalWords.contains(key) && (word.contains(where: \.isLetter) || isNumberInPhrase) {
                    frequency[key, default: 0] += 1
                    run.append(Token(range: range, key: key, isNoun: isNoun || isNumberInPhrase))
                } else { collect() }
                return true
            }
            collect()
        }
        func score(_ candidate: Candidate) -> Double {
            let relevance = candidate.keys.reduce(0.0) { $0 + log1p(Double(frequency[$1, default: 0])) }
            return Double(candidate.occurrences) * 4 + relevance / sqrt(Double(candidate.keys.count)) + Double(candidate.keys.count) * 0.4
        }
        return candidates.values.sorted {
            let lhs = score($0), rhs = score($1)
            return lhs == rhs ? $0.order < $1.order : lhs > rhs
        }.first?.text
    }
}
