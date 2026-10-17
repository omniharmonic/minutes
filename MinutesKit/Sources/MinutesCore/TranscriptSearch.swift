import Foundation

/// Literal, local search within one transcript. UTF-16 offsets can be converted
/// back to String ranges without confusing emoji or composed accents.
public struct TranscriptSearchMatch: Sendable, Equatable, Codable, Identifiable {
    public enum Field: String, Sendable, Codable { case text, speaker }
    public let utteranceID: Int
    public let field: Field
    public let location: Int
    public let length: Int
    public init(utteranceID: Int, field: Field, location: Int, length: Int) {
        self.utteranceID = utteranceID; self.field = field
        self.location = location; self.length = length
    }
    public var id: String { "\(utteranceID):\(field.rawValue):\(location):\(length)" }
    public var range: NSRange { NSRange(location: location, length: length) }
}

public enum TranscriptSearch {
    public static func matches(in utterances: [Utterance], query: String) -> [TranscriptSearchMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return utterances.flatMap { utterance in
            [(TranscriptSearchMatch.Field.speaker, utterance.speakerName), (.text, utterance.text)].flatMap { field, text in
                var matches: [TranscriptSearchMatch] = []
                var start = text.startIndex
                while start < text.endIndex,
                      let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex),
                      found.lowerBound < found.upperBound {
                    let range = NSRange(found, in: text)
                    matches.append(TranscriptSearchMatch(utteranceID: utterance.id, field: field, location: range.location, length: range.length))
                    start = found.upperBound
                }
                return matches
            }
        }
    }

    public static func advancedIndex(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((current + delta) % count + count) % count
    }
}
