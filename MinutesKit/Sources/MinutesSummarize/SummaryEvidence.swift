import Foundation
import MinutesCore

public enum SummaryTemplate: String, CaseIterable, Codable, Sendable {
    case general, oneToOne, standup, interview
    public var title: String {
        switch self { case .general: "General"; case .oneToOne: "1:1"; case .standup: "Standup"; case .interview: "Interview" }
    }
    var guidance: String {
        switch self {
        case .general: "Group supported discussion, potential decisions, follow-ups, and open questions."
        case .oneToOne: "Group supported check-ins, feedback, concerns, and follow-ups. Do not infer sentiment."
        case .standup: "Group explicitly stated progress, plans, and blockers. Do not infer commitments."
        case .interview: "Group questions and answers. Do not score people or infer qualifications."
        }
    }
}

struct SummaryEvidence: Encodable {
    let id: String
    let kind: String
    let speaker: String?
    let timing: String
    let text: String
    var additionalIDs: String? = nil

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else { return "unknown" }
        let millis = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d.%03d", millis / 60_000, (millis / 1_000) % 60, millis % 1_000)
    }

    static func records(meeting: Meeting, utterances: [Utterance]) -> [Self] {
        var records = utterances.enumerated().map { index, utterance in
            Self(id: String(format: "T%04d", index + 1), kind: "transcript", speaker: utterance.speakerName,
                 timing: meeting.platform == "transcript_import" ? "untimed" : "\(timecode(utterance.start))–\(timecode(utterance.end))",
                 text: utterance.text)
        }
        if let notes = meeting.userNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records.append(Self(id: "N0001", kind: "user_notes", speaker: nil, timing: "untimed personal context; not meeting speech", text: notes))
        }
        return records
    }

    private func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func validate(output: String, prompt: String) throws {
        let supplied = Set(suppliedIDs(in: prompt))
        let expression = try NSRegularExpression(pattern: #"\[([TN][0-9]{4,})\]"#)
        let claims = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !claims.isEmpty else { throw SummaryError.unsupportedEvidenceReference }
        for claim in claims {
            let matches = expression.matches(in: claim, range: NSRange(claim.startIndex..., in: claim))
            guard !matches.isEmpty, matches.allSatisfy({ match in
                guard let range = Range(match.range(at: 1), in: claim) else { return false }
                return supplied.contains(String(claim[range]))
            }) else { throw SummaryError.unsupportedEvidenceReference }
        }
    }

    static func suppliedIDs(in prompt: String) -> [String] {
        Set(prompt.components(separatedBy: "\n").flatMap { line -> [String] in
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  ["transcript", "user_notes", "draft_summary"].contains(object["kind"] ?? ""), let id = object["id"] else { return [] }
            return [id] + (object["additionalIDs"] ?? "").split(separator: " ").map(String.init)
        }).sorted()
    }

    /// The draft notes a reduction prompt carried, as cited bullets, for a
    /// chunk the model declined to condense.
    static func passThrough(prompt: String) -> String {
        prompt.components(separatedBy: "\n").compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                  record["kind"] == "draft_summary", let id = record["id"], let text = record["text"] else { return nil }
            let ids = [id] + (record["additionalIDs"] ?? "").split(separator: " ").map(String.init)
            return "- " + text + " " + ids.map { "[" + $0 + "]" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func draftRecords(_ outputs: [String]) throws -> [Self] {
        let expression = try NSRegularExpression(pattern: #"\[([TN][0-9]{4,})\]"#)
        var records: [Self] = []
        var seen: Set<String> = []
        for line in outputs.flatMap({ $0.components(separatedBy: "\n") }) {
            let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
            let ids = Set(matches.compactMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } }).sorted()
            guard let first = ids.first else { continue }
            let text = expression.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*")))
            let key = text.lowercased() + ids.joined(separator: " ")
            guard !text.isEmpty, seen.insert(key).inserted else { continue }
            records.append(Self(id: first, kind: "draft_summary", speaker: nil,
                timing: ids.allSatisfy { $0.hasPrefix("N") } ? "untimed personal context" : "intermediate draft; original source IDs retained",
                text: text, additionalIDs: ids.dropFirst().joined(separator: " ")))
        }
        return records
    }

    static func fittingPrompts(records: [Self], title: String, template: SummaryTemplate,
                               instructions: String, provider: any LLMProvider) async throws -> [String] {
        var bytes = provider.maximumInputBytes
        while true {
            let candidates = try prompts(records: records, title: title, template: template, instructions: instructions, maximumInputBytes: bytes)
            var fits = true
            for prompt in candidates {
                try Task.checkCancellation()
                if try await !provider.fitsInput(system: instructions, prompt: prompt) { fits = false; break }
            }
            if fits { return candidates }
            bytes = bytes * 3 / 4
            guard bytes >= 512 else { throw SummaryError.contextBudgetTooSmall }
        }
    }

    /// Each call is a fresh generation; input budgets include instructions,
    /// metadata, and JSON escaping. Oversized individual statements are split
    /// without inventing timing: each fragment retains the original range/id.
    static func prompts(records: [Self], title: String, template: SummaryTemplate,
                        instructions: String, maximumInputBytes: Int) throws -> [String] {
        let metadata = Self(id: "metadata", kind: "meeting_title", speaker: nil, timing: "untimed", text: title)
        let prefix = "Template: \(template.title)\nQuoted metadata:\n\(try metadata.encoded())\nQuoted evidence (JSON lines; fragments may share an id):\n"
        let fixed = instructions.utf8.count + prefix.utf8.count
        guard maximumInputBytes >= fixed + 256 else { throw SummaryError.contextBudgetTooSmall }
        let budget = maximumInputBytes - fixed
        guard budget >= 256 else { throw SummaryError.contextBudgetTooSmall }
        var fragments: [String] = []
        for record in records {
            let encoded = try record.encoded()
            if encoded.utf8.count + 1 <= budget { fragments.append(encoded); continue }
            let overhead = try Self(id: record.id, kind: record.kind, speaker: record.speaker, timing: record.timing, text: "").encoded().utf8.count
            let textBudget = budget - overhead - 1
            guard textBudget >= 16 else { throw SummaryError.contextBudgetTooSmall }
            var text = ""
            var bytes = 0
            for scalar in record.text.unicodeScalars {
                // JSON escapes control scalars, quotes and backslashes. Count
                // that representation rather than assuming characters=tokens.
                let cost: Int
                switch scalar.value {
                case 34, 92, 8, 9, 10, 12, 13: cost = 2
                case 0..<32: cost = 6
                default: cost = String(scalar).utf8.count
                }
                if bytes + cost > textBudget {
                    fragments.append(try Self(id: record.id, kind: record.kind, speaker: record.speaker, timing: record.timing, text: text).encoded())
                    text = ""; bytes = 0
                }
                text.unicodeScalars.append(scalar)
                bytes += cost
            }
            if !text.isEmpty { fragments.append(try Self(id: record.id, kind: record.kind, speaker: record.speaker, timing: record.timing, text: text).encoded()) }
        }
        var chunks: [String] = []
        var chunk = ""
        for fragment in fragments {
            if chunk.utf8.count + fragment.utf8.count + 1 > budget {
                chunks.append(prefix + chunk); chunk = ""
            }
            chunk += fragment + "\n"
        }
        if !chunk.isEmpty { chunks.append(prefix + chunk) }
        guard chunks.allSatisfy({ $0.utf8.count + instructions.utf8.count <= maximumInputBytes }) else { throw SummaryError.contextBudgetTooSmall }
        return chunks
    }
}
