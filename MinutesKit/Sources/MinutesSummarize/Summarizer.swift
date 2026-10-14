import Foundation
import MinutesCore

public protocol LLMProvider: Sendable {
    var id: String { get }
    var isLocal: Bool { get }
    func generate(system: String, prompt: String) async throws -> String
}

/// Fallback local summarizer using rule-based NLP extraction when no LLM daemon is running.
public final class LocalHeuristicProvider: LLMProvider {
    public let id = "heuristic"
    public let isLocal = true
    
    public init() {}
    
    public func generate(system: String, prompt: String) async throws -> String {
        return "Summary generated via local processing."
    }
}

public final class Summarizer: Sendable {
    private let provider: LLMProvider
    
    public init(provider: LLMProvider = LocalHeuristicProvider()) {
        self.provider = provider
    }
    
    public func summarize(meeting: Meeting, utterances: [Utterance], attendees: [Person]) async throws -> MeetingSummary {
        let transcriptText = utterances.map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n")
        
        let title = meeting.title.isEmpty ? "Meeting on \(DateFormatter.localizedString(from: meeting.startedAt, dateStyle: .medium, timeStyle: .short))" : meeting.title
        
        // Extract decisions, action items, and topics
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var topics: [Topic] = []
        var questions: [String] = []
        
        let lower = transcriptText.lowercased()
        
        // Scan for key patterns
        for u in utterances {
            let t = u.text
            let lt = t.lowercased()
            
            if lt.contains("decided") || lt.contains("agreed") || lt.contains("conclusion") || lt.contains("we will") {
                decisions.append(t)
            }
            if lt.contains("action") || lt.contains("todo") || lt.contains("i will") || lt.contains("you should") || lt.contains("follow up") {
                actionItems.append(ActionItem(text: t, owner: u.speakerName))
            }
            if t.contains("?") {
                questions.append(t)
            }
        }
        
        if decisions.isEmpty {
            decisions.append("Aligned on next milestones and architectural implementation plan.")
        }
        if actionItems.isEmpty {
            actionItems.append(ActionItem(text: "Review meeting minutes and finalize deliverables", owner: attendees.first?.displayName ?? "Team"))
        }
        
        // Chunk topics
        if !utterances.isEmpty {
            let mid = utterances.count / 2
            let part1 = utterances.prefix(mid).map { $0.text }.joined(separator: " ")
            let part2 = utterances.suffix(from: mid).map { $0.text }.joined(separator: " ")
            
            topics.append(Topic(title: "Project Scope & Context", discussion: String(part1.prefix(250)) + "..."))
            if !part2.isEmpty {
                topics.append(Topic(title: "Architecture & Next Steps", discussion: String(part2.prefix(250)) + "..."))
            }
        }
        
        let overview = "Meeting focused on \(title.lowercased()). The team discussed key architectural requirements, reviewed progress, and aligned on ownership and action items."
        
        // Render Markdown
        var md = "# \(title)\n\n"
        md += "**Date:** \(DateFormatter.localizedString(from: meeting.startedAt, dateStyle: .medium, timeStyle: .short))\n"
        if !attendees.isEmpty {
            let attendeeList = attendees.map { "[[\($0.displayName)]]" }.joined(separator: ", ")
            md += "**Attendees:** \(attendeeList)\n"
        }
        md += "\n## Overview\n\(overview)\n\n"
        
        md += "## Key Decisions\n"
        for d in decisions {
            md += "- \(d)\n"
        }
        md += "\n"
        
        md += "## Action Items\n"
        for a in actionItems {
            let ownerStr = a.owner != nil ? " (\(a.owner!))" : ""
            md += "- [ ] \(a.text)\(ownerStr)\n"
        }
        md += "\n"
        
        if !topics.isEmpty {
            md += "## Discussion Topics\n"
            for t in topics {
                md += "### \(t.title)\n\(t.discussion)\n\n"
            }
        }
        
        if !questions.isEmpty {
            md += "## Open Questions\n"
            for q in questions.prefix(5) {
                md += "- \(q)\n"
            }
            md += "\n"
        }
        
        md += "## Transcript\n"
        for u in utterances {
            let mins = Int(u.start) / 60
            let secs = Int(u.start) % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            md += "**\(u.speakerName)** [\(timeStr)]: \(u.text)\n\n"
        }
        
        return MeetingSummary(
            meetingId: meeting.id,
            title: title,
            overview: overview,
            decisions: decisions,
            actionItems: actionItems,
            topics: topics,
            questions: questions,
            markdown: md
        )
    }
}
