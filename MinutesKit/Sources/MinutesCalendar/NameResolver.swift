import Foundation

public enum NameResolver {
    /// Cleans email string (removes 'mailto:', lowercase, trim whitespace)
    public static func cleanEmail(_ raw: String) -> String {
        var email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if email.hasPrefix("mailto:") {
            email = String(email.dropFirst(7))
        }
        return email
    }
    
    /// Heuristically resolves a person's display name from their email address.
    /// E.g. "ana.lopez@stripe.com" -> "Ana Lopez", "john_doe@apple.com" -> "John Doe"
    public static func resolveDisplayName(fromEmail rawEmail: String) -> String {
        let email = cleanEmail(rawEmail)
        guard let localPart = email.components(separatedBy: "@").first, !localPart.isEmpty else {
            return rawEmail
        }
        
        // Split by '.', '_', '-'
        let separators = CharacterSet(charactersIn: "._-+")
        let tokens = localPart.components(separatedBy: separators).filter { !$0.isEmpty }
        
        if tokens.isEmpty {
            return localPart.capitalized
        }
        
        // Capitalize each token
        let words = tokens.map { token -> String in
            // Remove trailing numbers if any (e.g. "john2")
            let stripped = token.trimmingCharacters(in: .decimalDigits)
            if stripped.isEmpty { return token }
            return stripped.prefix(1).uppercased() + stripped.dropFirst().lowercased()
        }
        
        return words.joined(separator: " ")
    }
}

public enum ConferenceLinkParser {
    private static let meetRegex = try! NSRegularExpression(pattern: #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .caseInsensitive)
    private static let zoomRegex = try! NSRegularExpression(pattern: #"https://([a-z0-9]+\.)?zoom\.us/j/\d+"#, options: .caseInsensitive)
    private static let teamsRegex = try! NSRegularExpression(pattern: #"https://teams\.microsoft\.com/l/meetup-join/[^\s\>]+"#, options: .caseInsensitive)
    
    /// Parses conference URLs from text (notes, location, description).
    public static func parseConferenceURL(from text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        
        if let match = meetRegex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range, in: text) {
            return String(text[r])
        }
        if let match = zoomRegex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range, in: text) {
            return String(text[r])
        }
        if let match = teamsRegex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range, in: text) {
            return String(text[r])
        }
        return nil
    }
}
