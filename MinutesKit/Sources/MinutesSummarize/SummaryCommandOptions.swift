import Foundation

public enum SummaryEngine: String, CaseIterable, Sendable { case extractive, apple }

/// Shared by the CLI so invalid selections fail before invoking a provider.
public struct SummaryCommandOptions: Sendable {
    public let engine: SummaryEngine
    public let template: SummaryTemplate
    public init(arguments: [String]) throws {
        var engine = SummaryEngine.extractive
        var template = SummaryTemplate.general
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--engine", "--template", "--data-dir"].contains(flag), seen.insert(flag).inserted,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else { throw Self.invalid() }
            index += 1
            let value = arguments[index]
            switch flag {
            case "--engine": guard let selected = SummaryEngine(rawValue: value) else { throw Self.invalid() }; engine = selected
            case "--template": guard let selected = SummaryTemplate(rawValue: value) else { throw Self.invalid() }; template = selected
            default: break // Existing global storage option, handled by the CLI.
            }
            index += 1
        }
        self.engine = engine
        self.template = template
    }
    private static func invalid() -> NSError {
        NSError(domain: "Minutes.Summary.Options", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Usage: summarize <meeting-id> [--engine apple|extractive] [--template general|oneToOne|standup|interview] [--data-dir <directory>]"])
    }
}
