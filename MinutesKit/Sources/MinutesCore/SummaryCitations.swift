import Foundation

/// Summaries cite transcript evidence as `[T0006]` (the sixth utterance at
/// summary time) and user notes as `[N0001]`. People read those as times.
public enum SummaryCitations {
    public struct Citation: Sendable, Equatable {
        public let id: String
        /// Utterance start in seconds; nil for notes or ids outside the transcript.
        public let seconds: Double?
    }

    /// One or more ids in a bracket, e.g. `[T0006]`, `[T0006, T0012]`.
    private static let group = try! NSRegularExpression(pattern: #"\s?\[((?:[TN]\d{3,})(?:\s*[,;]\s*[TN]\d{3,})*)\]"#)

    public static func resolve(_ id: String, utterances: [Utterance], timed: Bool = true) -> Citation {
        guard timed, id.hasPrefix("T"), let index = Int(id.dropFirst()), utterances.indices.contains(index - 1) else {
            return Citation(id: id, seconds: nil)
        }
        return Citation(id: id, seconds: utterances[index - 1].start)
    }

    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Replaces citation groups using `render`, which receives the resolved citations
    /// of one group and returns its replacement (empty drops the group).
    public static func replacing(in markdown: String, utterances: [Utterance], timed: Bool = true,
                                 render: ([Citation]) -> String) -> String {
        let source = markdown as NSString
        var result = ""
        var cursor = 0
        for match in group.matches(in: markdown, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ids = source.substring(with: match.range(at: 1))
                .components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }
            result += render(ids.map { resolve($0, utterances: utterances, timed: timed) })
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    /// Readable Markdown for exports and the CLI: `[T0006]` becomes ` (12:04)`;
    /// note and unresolvable citations are dropped.
    public static func readableMarkdown(_ markdown: String, utterances: [Utterance], timed: Bool = true) -> String {
        replacing(in: markdown, utterances: utterances, timed: timed) { citations in
            let times = uniqueTimes(citations)
            return times.isEmpty ? "" : " (" + times.map(timecode).joined(separator: ", ") + ")"
        }
    }

    /// Display Markdown with inline links `[12:04](minutes-seek:724.0)` the app opens as seeks.
    public static func linkedMarkdown(_ markdown: String, utterances: [Utterance], timed: Bool = true) -> String {
        replacing(in: markdown, utterances: utterances, timed: timed) { citations in
            let times = uniqueTimes(citations)
            return times.isEmpty ? "" : " " + times.map { "[\(timecode($0))](\(seekScheme):\(String(format: "%.3f", $0)))" }.joined(separator: " ")
        }
    }

    public static let seekScheme = "minutes-seek"

    /// The playback position encoded in a `linkedMarkdown` link.
    public static func seconds(from url: URL) -> Double? {
        guard url.scheme == seekScheme else { return nil }
        return Double(url.absoluteString.dropFirst(seekScheme.count + 1)).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private static func uniqueTimes(_ citations: [Citation]) -> [Double] {
        var seen = Set<Int>()
        return citations.compactMap(\.seconds).filter { seen.insert(Int($0)).inserted }.sorted()
    }
}
