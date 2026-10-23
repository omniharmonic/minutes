import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum LocalSummaryAvailability: Equatable, Sendable {
    case available, requiresNewerOS, deviceNotEligible, appleIntelligenceDisabled, modelNotReady, unavailable
    public var message: String {
        switch self {
        case .available: "Apple on-device summaries are available."
        case .requiresNewerOS: "Apple on-device summaries require macOS 26 or iOS 26 or later."
        case .deviceNotEligible: "This device does not support Apple Intelligence. Extractive notes remain available."
        case .appleIntelligenceDisabled: "Enable Apple Intelligence in your device settings to use Apple on-device summaries."
        case .modelNotReady: "Apple Intelligence's on-device model is not ready. Complete setup in your device settings and try again."
        case .unavailable: "Apple on-device summaries are currently unavailable. Extractive notes remain available."
        }
    }
}

/// Uses only the device's SystemLanguageModel. No cloud provider, model download,
/// or automatic substitution is invoked by this adapter.
public struct FoundationModelsProvider: LLMProvider {
    public let id = "apple-foundation-models-on-device"
    public let isLocal = true
    // Conservative UTF-8 upper bound, including instructions and prompt: about
    // one byte per token, leaving room for output and framing. 2,800 fits the
    // 26.x 4096-token context; newer systems report a larger context, so long
    // meetings need fewer requests. A context failure is surfaced, not hidden.
    public var maximumInputBytes: Int { Self.inputBudget(contextTokens: Self.contextTokens()) }
    /// Waits before retrying a busy (rate-limited) model. Apple limits requests
    /// from apps in the background, which a long meeting quickly reaches.
    let busyRetryDelays: [Duration]
    public init(busyRetryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(30)]) {
        self.busyRetryDelays = busyRetryDelays
    }

    static func inputBudget(contextTokens: Int) -> Int { max(2_800, contextTokens - 1_300) }

    static func contextTokens() -> Int {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4_096
    }

    /// A saved choice always wins. Eligible fresh installations use the local model.
    public static func initialPreference(savedChoice: Bool?, availability: LocalSummaryAvailability) -> Bool {
        savedChoice ?? (availability == .available)
    }

    public static func availability() -> LocalSummaryAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceDisabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unavailable
                }
            }
        }
        #endif
        return .requiresNewerOS
    }

    public func generate(system: String, prompt: String) async throws -> String {
        try await Self.retryingBusy(delays: busyRetryDelays) {
            try await Self.preferringText(
                text: { try await generatePermissiveText(system: system, prompt: prompt) },
                guided: { try await generateOnce(system: system, prompt: prompt) })
        }
    }

    /// Plain text under permissive guardrails first; guided generation, under
    /// the default guardrails, only when the text attempt is refused, uncited
    /// or fails. Busy and cancellation propagate so the request is retried.
    static func preferringText<T>(text: () async throws -> T, guided: () async throws -> T) async throws -> T {
        do { return try await text() }
        catch is CancellationError { throw CancellationError() }
        catch LocalSummaryProviderError.busy { throw LocalSummaryProviderError.busy }
        catch {
            Logger(subsystem: "app.minutes", category: "LocalSummary").info("Text attempt unusable (\(String(describing: error), privacy: .public)); using guided generation")
            return try await guided()
        }
    }

    /// The Markdown bullets of a text response, normalized to "- " with each
    /// cited ID in its own brackets.
    static func textBullets(_ response: String) -> [String] {
        response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { normalizedCitations("- " + $0.dropFirst(2)) }
    }

    /// Plain text cites loosely: "[T0003, T0004]", "(T0003)", "T0003". Groups of
    /// IDs become trailing "[T0003] [T0004]"; validation still checks each one.
    static func normalizedCitations(_ bullet: String) -> String {
        let id = #"[TN][0-9]{4,}"#
        let group = #"\s*[\[(]\s*(?:Source IDs?:?\s*)?"# + id + #"(?:\s*[,;&]?\s*(?:and\s+)?"# + id + #")*\s*[\])]|\s*\b"# + id + #"\b"#
        guard let expression = try? NSRegularExpression(pattern: id),
              let groups = try? NSRegularExpression(pattern: group, options: .caseInsensitive) else { return bullet }
        let range = NSRange(bullet.startIndex..., in: bullet)
        let ids = expression.matches(in: bullet, range: range).compactMap { Range($0.range, in: bullet).map { String(bullet[$0]) } }
        guard !ids.isEmpty else { return bullet }
        var text = groups.stringByReplacingMatches(in: bullet, range: range, withTemplate: "")
        // A bare "Sources: T0003 and T0005" leaves its label behind.
        text = text.replacingOccurrences(of: #"(?:\s*(?:\(?source IDs?:?|sources?:|and|,|;|\(|\)))+\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        var seen: Set<String> = []
        return text + " " + ids.filter { seen.insert($0).inserted }.map { "[\($0)]" }.joined(separator: " ")
    }

    /// Retries `operation` after each delay while the model reports it is busy.
    static func retryingBusy<T>(delays: [Duration], _ operation: () async throws -> T) async throws -> T {
        var remaining = delays[...]
        while true {
            do { return try await operation() }
            catch LocalSummaryProviderError.busy where !remaining.isEmpty {
                try await Task.sleep(for: remaining.removeFirst())
            }
        }
    }

    private func generateOnce(system: String, prompt: String) async throws -> String {
        let status = Self.availability()
        guard status == .available else { throw LocalSummaryProviderError.unavailable(status) }
        guard system.utf8.count + prompt.utf8.count <= maximumInputBytes else { throw SummaryError.contextBudgetTooSmall }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            // Sessions retain their transcript. A new session for each bounded
            // request prevents earlier chunks from consuming the next context.
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
            do {
                if system.hasPrefix("Extract explicit outcomes.") {
                    let response = try await session.respond(to: prompt, generating: NativeOutcomesDraft.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 512))
                    func line(_ kind: String, _ claim: NativeSummaryClaim) -> String {
                        let text = claim.text.components(separatedBy: .newlines).joined(separator: " ")
                        return "- \(kind): " + text + " " + claim.evidenceIDs.map { "[" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) + "]" }.joined(separator: " ")
                    }
                    return (response.content.decisions.map { line("Decision", $0) } + response.content.actionItems.map { line("Action", $0) }).joined(separator: "\n")
                }
                if system.contains("Summary length: brief.") {
                    let response = try await session.respond(to: prompt, generating: NativeBriefSummaryDraft.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 256))
                    let main = response.content.mainPoint.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    let reason = response.content.supportingReason?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    var text = main
                    if let reason, !reason.isEmpty, reason.lowercased() != main.lowercased() {
                        text = main.replacingOccurrences(of: #"[.!?;:]\s*$"#, with: "", options: .regularExpression) + "; " + reason
                    }
                    let references = response.content.evidenceIDs.map { "[" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) + "]" }.joined(separator: " ")
                    return "- " + text + " " + references
                }
                let claims: [NativeSummaryClaim]
                // Reductions must contract: the six-claim schema let each pass
                // return nearly as many bullets as it received, so a 37-minute
                // call never converged. Draft-fact prompts get the 1...3 schema.
                if prompt.utf8.count <= 1_400 || prompt.contains(#""kind":"draft_summary""#) {
                    let response = try await session.respond(to: prompt, generating: NativeCompactSummaryDraft.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 512))
                    claims = response.content.claims
                } else {
                    let response = try await session.respond(to: prompt, generating: NativeSummaryDraft.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 768))
                    claims = response.content.claims
                }
                let points = claims.map { claim in
                    let text = claim.text.components(separatedBy: .newlines).joined(separator: " ")
                    let references = claim.evidenceIDs.map { "[" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) + "]" }.joined(separator: " ")
                    return "- " + text + " " + references
                }
                return Self.withUnansweredQuestions(points, prompt: prompt)
            } catch is CancellationError { throw CancellationError() }
            catch let error as LanguageModelSession.GenerationError {
                try Task.checkCancellation()
                Logger(subsystem: "app.minutes", category: "LocalSummary").error("Generation error \(String(describing: error).prefix(while: { $0 != "(" }), privacy: .public) promptBytes=\(prompt.utf8.count, privacy: .public)")
                switch error {
                case .exceededContextWindowSize: throw LocalSummaryProviderError.contextLimit
                case .assetsUnavailable: throw LocalSummaryProviderError.unavailable(.modelNotReady)
                case .guardrailViolation, .refusal: throw LocalSummaryProviderError.contentDeclined
                case .decodingFailure: throw LocalSummaryProviderError.invalidResponse
                case .rateLimited, .concurrentRequests: throw LocalSummaryProviderError.busy
                case .unsupportedLanguageOrLocale: throw LocalSummaryProviderError.unsupportedLanguage
                case .unsupportedGuide: throw LocalSummaryProviderError.unsupportedResponse
                @unknown default: throw LocalSummaryProviderError.generationFailed
                }
            } catch let error as LocalSummaryProviderError { throw error }
            catch {
                try Task.checkCancellation()
                // iOS/macOS 27 report model failures as LanguageModelError, not
                // GenerationError; unmapped, one declined chunk failed the summary.
                if #available(macOS 27, iOS 27, *), let error = error as? LanguageModelError {
                    Logger(subsystem: "app.minutes", category: "LocalSummary").error("Language model error \(String(describing: error).prefix(while: { $0 != "(" }), privacy: .public) promptBytes=\(prompt.utf8.count, privacy: .public)")
                    throw Self.providerError(error)
                }
                let failure = error as NSError
                Logger(subsystem: "app.minutes", category: "LocalSummary").error("Generation failure domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
                throw LocalSummaryProviderError.generationFailed
            }
        }
        #endif
        throw LocalSummaryProviderError.unavailable(.requiresNewerOS)
    }

    #if canImport(FoundationModels)
    @available(macOS 27, iOS 27, *)
    static func providerError(_ error: LanguageModelError) -> LocalSummaryProviderError {
        switch error {
        case .contextSizeExceeded: .contextLimit
        case .rateLimited, .timeout: .busy
        case .guardrailViolation, .refusal: .contentDeclined
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .unsupportedGenerationGuide, .unsupportedCapability, .unsupportedTranscriptContent: .unsupportedResponse
        @unknown default: .generationFailed
        }
    }
    #endif

    /// Guided generation always applies the default guardrails, which decline
    /// ordinary meeting talk. Summarizing the user's own transcript is the
    /// content transformation Apple's permissive mode exists for, but only for
    /// String output, so requests are made as cited text bullets first. The
    /// caller still rejects any bullet that lacks supplied evidence IDs.
    private func generatePermissiveText(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let outcomes = system.hasPrefix("Extract explicit outcomes.")
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                               instructions: Self.textInstructions(system: system, outcomes: outcomes))
            let content: String
            do {
                content = try await session.respond(to: Self.plainEvidence(prompt) + "\nNotes:",
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 768)).content
            } catch is CancellationError { throw CancellationError() }
            catch let error as LanguageModelSession.GenerationError {
                try Task.checkCancellation()
                Logger(subsystem: "app.minutes", category: "LocalSummary").error("Text generation error \(String(describing: error).prefix(while: { $0 != "(" }), privacy: .public) promptBytes=\(prompt.utf8.count, privacy: .public)")
                switch error {
                case .rateLimited, .concurrentRequests: throw LocalSummaryProviderError.busy
                default: throw LocalSummaryProviderError.contentDeclined
                }
            } catch {
                try Task.checkCancellation()
                if #available(macOS 27, iOS 27, *), let error = error as? LanguageModelError {
                    Logger(subsystem: "app.minutes", category: "LocalSummary").error("Text language model error \(String(describing: error).prefix(while: { $0 != "(" }), privacy: .public) promptBytes=\(prompt.utf8.count, privacy: .public)")
                    if case .busy = Self.providerError(error) { throw LocalSummaryProviderError.busy }
                }
                throw LocalSummaryProviderError.contentDeclined
            }
            return try Self.citedText(content, outcomes: outcomes, prompt: prompt)
        }
        #endif
        throw LocalSummaryProviderError.contentDeclined
    }

    /// Guided schemas carried the note-taking discipline; plain text needs it
    /// stated, with an example. Without one the model copied quoted lines.
    static func textInstructions(system: String, outcomes: Bool) -> String {
        let task = outcomes
            ? "Reply only with lines \"- Decision: \" or \"- Action: \", one sentence each, ending with its source IDs in brackets. If there are none, reply \"None\"."
            : system.hasPrefix("Write a coherent whole-meeting brief")
            ? "Each line is a draft note. Write at most three short bullets that combine them in your own words, with fewer words than the notes. End each bullet with every source ID it relies on."
            : system.contains("Summary length: brief.")
            ? "Write exactly one bullet that states the main point and its reason in your own words, ending with its source IDs in brackets."
            : "Write up to six bullets of notes: decisions, plans, owners, reasons, next steps and open issues. Rephrase concisely in your own words and merge related lines; never copy a sentence. Skip microphone checks, greetings and introductions. End each bullet with the source IDs it relies on."
        return """
        You write meeting notes from a transcript. Each line starts with its source IDs in brackets. \(task)

        Example:
        Transcript:
        [T0001] Testing, can you hear me?
        [T0002] Let's move the launch to May because the venue is booked. Sam will email the vendor.
        Notes:
        - Launch moves to May because the venue is booked; Sam will email the vendor. [T0002]

        Rules: \(system)
        """
    }

    /// The JSON evidence lines of a prompt as "[IDs] Speaker: text" lines.
    static func plainEvidence(_ prompt: String) -> String {
        var title = "", lines: [String] = []
        for line in prompt.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                  let text = record["text"] else { continue }
            switch record["kind"] {
            case "meeting_title": title = text
            case "transcript", "user_notes", "draft_summary":
                guard let id = record["id"] else { continue }
                let ids = ([id] + (record["additionalIDs"] ?? "").split(separator: " ").map(String.init)).map { "[\($0)]" }.joined(separator: " ")
                let speaker = record["kind"] == "user_notes" ? "Personal note" : record["speaker"].flatMap { $0.isEmpty || ["Unknown", "Unassigned"].contains($0) ? nil : $0 }
                lines.append(ids + " " + (speaker.map { $0 + ": " } ?? "") + text)
            default: continue
            }
        }
        return (title.isEmpty ? "" : "Meeting: \(title)\n") + "Transcript:\n" + lines.joined(separator: "\n")
    }

    /// The usable bullets of a text response. No cited bullet means a refusal
    /// or unusable answer, except that outcome extraction may find none.
    static func citedText(_ content: String, outcomes: Bool, prompt: String) throws -> String {
        let bullets = textBullets(content)
        if outcomes { return bullets.joined(separator: "\n") }
        guard bullets.contains(where: { $0.range(of: #"\[[TN][0-9]{4,}\]"#, options: .regularExpression) != nil }) else {
            // Shape only; the response may quote the transcript.
            let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            Logger(subsystem: "app.minutes", category: "LocalSummary").info("Uncited text: bytes=\(content.utf8.count, privacy: .public) lines=\(lines.count, privacy: .public) bullets=\(bullets.count, privacy: .public) ids=\(content.range(of: #"[TN][0-9]{4}"#, options: .regularExpression) != nil, privacy: .public)")
            throw LocalSummaryProviderError.contentDeclined
        }
        // Reductions restate notes; only transcript prompts carry open questions.
        guard !prompt.contains(#""kind":"draft_summary""#) else { return bullets.joined(separator: "\n") }
        return withUnansweredQuestions(bullets, prompt: prompt)
    }

    /// The local model repeatedly invented unanswered questions from answered
    /// negations, even under a constrained question schema. Retain explicit
    /// unknowns as source excerpts; never manufacture uncertainty or reject
    /// the entire otherwise usable draft.
    static func withUnansweredQuestions(_ points: [String], prompt: String) -> String {
        let questions = SummaryQuestionEvidence.unansweredExcerpts(prompt: prompt).filter { excerpt in
            !points.contains { $0.localizedCaseInsensitiveContains(excerpt.text) }
        }.map { excerpt in "- " + excerpt.text + " " + excerpt.evidenceIDs.map { "[" + $0 + "]" }.joined(separator: " ") }
        return (points + questions).joined(separator: "\n")
    }
}

/// Unanswered questions must quote an actual excerpt from their cited evidence.
/// Schema guidance alone cannot establish that a generated question was asked.
enum SummaryQuestionEvidence {
    struct Excerpt { let id: String; let text: String; let additionalIDs: [String]; var evidenceIDs: [String] { [id] + additionalIDs } }
    static func unansweredExcerpts(prompt: String) -> [Excerpt] {
        // Conversational "I don't know who you are" is not an open issue, and
        // Apple Speech emits run-on sentences; neither may become a quoted bullet.
        let pattern = #"\b(?:we|i|they|the team)\s+(?:still\s+)?need to (?:know|determine|find out|understand)\b|\b(?:we|they|the team)\s+(?:still\s+)?(?:don[’']t|do not) know (?:whether|if)\b|\b(?:unanswered|open) question\b|\b(?:unclear|unknown) whether\b|\bstill (?:unclear|unknown)\b"#
        return prompt.components(separatedBy: .newlines).flatMap { line -> [Excerpt] in
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                  ["transcript", "draft_summary"].contains(record["kind"] ?? ""),
                  let text = record["text"], let id = record["id"] else { return [] }
            var excerpts: [Excerpt] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
                guard let sentence, sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return }
                let quote = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard quote.count <= 240 else { return }
                if supports(excerpt: quote, ids: [id], prompt: prompt) { excerpts.append(Excerpt(id: id, text: quote, additionalIDs: (record["additionalIDs"] ?? "").split(separator: " ").map(String.init))) }
            }
            return excerpts
        }
    }
    static func supports(excerpt: String, ids: [String], prompt: String) -> Bool {
        let quoted = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoted.isEmpty, !ids.isEmpty else { return false }
        let requested = Set(ids.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) })
        return prompt.components(separatedBy: .newlines).contains { line in
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                  let text = record["text"], let id = record["id"] else { return false }
            let supplied = Set([id] + (record["additionalIDs"] ?? "").split(separator: " ").map(String.init))
            return !requested.isDisjoint(with: supplied) && text.contains(quoted)
        }
    }
}

public enum LocalSummaryProviderError: Error, LocalizedError, Sendable {
    case unavailable(LocalSummaryAvailability), generationFailed, contextLimit, contentDeclined, invalidResponse, busy, unsupportedLanguage, unsupportedResponse
    public var errorDescription: String? {
        switch self {
        case .unavailable(let status): status.message
        case .contextLimit: "The local model's context limit was reached. The transcript is saved; choose a shorter summary or retry."
        case .contentDeclined: "Apple’s local model declined this content. Your transcript is saved; extractive notes remain available."
        case .invalidResponse: "Apple’s local model returned an incomplete summary. Your transcript is saved; try generating it again."
        case .busy: "Apple’s local model is busy. Your transcript is saved; retry the summary shortly."
        case .unsupportedLanguage: "Apple’s local model does not support the requested language or locale. Your transcript is saved."
        case .unsupportedResponse: "Apple’s local model cannot use this summary format on the current OS. Your transcript is saved."
        case .generationFailed: "Apple on-device summary generation could not complete. Your transcript and notes are preserved. Retry or explicitly choose extractive notes."
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable(description: "A short draft grounded only in the supplied evidence; never infer owners or commitments.")
private struct NativeSummaryDraft {
    @Guide(description: "Write up to six useful, nonredundant points. Preserve concrete outcomes and reasons and each distinct explicit follow-up. Combine related actions while retaining every supplied owner, condition and time. Retain unresolved issues only when explicitly present. Use fewer points when sufficient; never fill a quota or narrate that participants discussed something.", .count(1...6))
    var claims: [NativeSummaryClaim]

}

@available(macOS 26, iOS 26, *)
@Generable(description: "A compact summary grounded only in supplied evidence.")
private struct NativeCompactSummaryDraft {
    @Guide(description: "One to three concise useful points. Combine related tasks while retaining their named owners, conditions and times. Preserve concrete outcomes and reasons. Omit greetings, recording checks, generic narration, and statements about absent categories. Do not fill a quota.", .count(1...3))
    var claims: [NativeSummaryClaim]
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Exactly one concise useful point for a brief recording.")
private struct NativeBriefSummaryDraft {
    @Guide(description: "The main request, outcome, or point in a few words. For a check or question, state the purpose or actual question; do not turn it into an unsupported claim about system reliability or generic 'unclear' wording. No meeting metadata or generic discussion narration.")
    var mainPoint: String
    @Guide(description: "The other supplied fact explaining why the main point matters, or its explicit condition or blocker. Preserve negation. Include it whenever present; nil only if the source gives no such supporting detail. Never invent an explanation.")
    var supportingReason: String?
    @Guide(description: "Exact source IDs supporting the main point and supporting reason, copied from the supplied evidence. No brackets or invented IDs.", .count(1...3))
    var evidenceIDs: [String]
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Explicit outcomes only; empty lists are expected when none were stated.")
private struct NativeOutcomesDraft {
    @Guide(description: "Decisions the speakers explicitly made or agreed. Preserve negation and conditions. Empty if none.", .maximumCount(3))
    var decisions: [NativeSummaryClaim]
    @Guide(description: "Tasks someone explicitly committed to or was asked to do, with the named owner and timing only when stated. Empty if none.", .maximumCount(4))
    var actionItems: [NativeSummaryClaim]
}

@available(macOS 26, iOS 26, *)
@Generable
private struct NativeSummaryClaim {
    @Guide(description: "State a concrete supported outcome, reason, next step, or unresolved issue directly. For an unresolved question, retain exactly what remains unknown and its distinguishing condition or environment; if someone will investigate, combine the question and their follow-up. Do not reduce a specific open question to a vague topic. Avoid generic discussion descriptions, transcript metadata, and redundant restatements. Preserve negation. Personal notes stay personal context, not decisions.")
    var text: String
    @Guide(description: "Copy exact supporting source IDs from id or additionalIDs in the supplied evidence. Never invent IDs or include brackets in these fields.", .count(1...3))
    var evidenceIDs: [String]
}

#endif
