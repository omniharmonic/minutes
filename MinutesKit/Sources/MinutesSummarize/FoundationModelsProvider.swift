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
        try await Self.retryingBusy(delays: busyRetryDelays) { try await generateOnce(system: system, prompt: prompt) }
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
                // The local model repeatedly invented unanswered questions from
                // answered negations, even under a constrained question schema.
                // Retain explicit unknowns as source excerpts; never manufacture
                // uncertainty or reject the entire otherwise usable draft.
                let questions = SummaryQuestionEvidence.unansweredExcerpts(prompt: prompt).filter { excerpt in
                    !points.contains { $0.localizedCaseInsensitiveContains(excerpt.text) }
                }.map { excerpt in "- " + excerpt.text + " " + excerpt.evidenceIDs.map { "[" + $0 + "]" }.joined(separator: " ") }
                return (points + questions).joined(separator: "\n")
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
                let failure = error as NSError
                Logger(subsystem: "app.minutes", category: "LocalSummary").error("Generation failure domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
                throw LocalSummaryProviderError.generationFailed
            }
        }
        #endif
        throw LocalSummaryProviderError.unavailable(.requiresNewerOS)
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
