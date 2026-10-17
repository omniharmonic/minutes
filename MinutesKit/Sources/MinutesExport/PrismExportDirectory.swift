import Foundation

/// Relative vault paths only. Server-owned opaque import IDs remain underneath
/// this directory, so exports never overwrite a user-authored note.
public enum PrismExportDirectory {
    public static func validate(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 240, parts.count <= 8,
              parts.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".") &&
                  part.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
              }) else {
            throw PrismError.invalidPayload("Use a relative vault folder such as Minutes or Meetings/Work, with letters, numbers, spaces, hyphens or underscores.")
        }
    }
}
