import Foundation
import MinutesCore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public struct FolderClassificationInput: Sendable, Equatable {
    public let title: String
    public let summary: String
    public let notes: String
    public init(title: String, summary: String = "", notes: String = "") {
        self.title = title; self.summary = summary; self.notes = notes
    }
    fileprivate var text: String {
        [String(title.prefix(200)), String(summary.prefix(1_000)), String(notes.prefix(600))]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

public struct FolderClassificationCandidate: Sendable, Equatable {
    public let folder: MeetingFolder
    /// Only examples a person explicitly filed in this folder. Automatic output
    /// must never train its next prediction. At most five examples are compared.
    public let manualExamples: [String]
    public init(folder: MeetingFolder, manualExamples: [String] = []) { self.folder = folder; self.manualExamples = manualExamples }
}

public enum FolderClassificationStatus: String, Codable, Sendable {
    case matched, ambiguous, unrelated, modelUnavailable, insufficientContent, noFolders
}

public struct FolderClassificationResult: Sendable, Equatable {
    public let folderID: String?
    public let status: FolderClassificationStatus
    public let reason: String
    /// Cosine similarity and separation, never probabilities or confidence.
    public let similarity: Double?
    public let margin: Double?
    public init(folderID: String? = nil, status: FolderClassificationStatus, reason: String, similarity: Double? = nil, margin: Double? = nil) {
        self.folderID = folderID; self.status = status; self.reason = reason; self.similarity = similarity; self.margin = margin
    }
}

public protocol FolderSemanticEmbeddingProvider: Sendable {
    /// All returned vectors must use one model/language and preserve input order.
    /// nil means the installed model cannot handle this input. Never download.
    func embeddings(for texts: [String]) async throws -> [[Double]]?
}

/// Loads only Apple's installed sentence model for the input's detected language.
/// This API does not request a model asset download or contact a remote service.
public actor NaturalLanguageFolderEmbeddingProvider: FolderSemanticEmbeddingProvider {
    public init() {}
    public func embeddings(for texts: [String]) async throws -> [[Double]]? {
        #if canImport(NaturalLanguage)
        guard let input = texts.first, let language = NLLanguageRecognizer.dominantLanguage(for: input),
              let model = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        var result: [[Double]] = []
        for text in texts {
            try Task.checkCancellation()
            guard let vector = model.vector(for: text) else { return nil }
            result.append(vector)
        }
        return result
        #else
        return nil
        #endif
    }
}

/// Conservative semantic filing. Every candidate is ranked; a weak best match or
/// close runner-up leaves the meeting Unfiled. Persistence/manual locks are Core's
/// responsibility, so callers must commit via applyAutomaticFolder's revision CAS.
public struct FolderClassifier: Sendable {
    private let embeddingProvider: any FolderSemanticEmbeddingProvider
    private let minimumSimilarity: Double
    private let minimumMargin: Double
    public init(embeddingProvider: any FolderSemanticEmbeddingProvider = NaturalLanguageFolderEmbeddingProvider(), minimumSimilarity: Double = 0.72, minimumMargin: Double = 0.12) {
        self.embeddingProvider = embeddingProvider
        self.minimumSimilarity = max(0.72, minimumSimilarity)
        self.minimumMargin = max(0.12, minimumMargin)
    }
    public func classify(input: FolderClassificationInput, candidates: [FolderClassificationCandidate]) async -> FolderClassificationResult {
        guard !candidates.isEmpty else { return FolderClassificationResult(status: .noFolders, reason: "Create a folder before automatic filing.") }
        let text = input.text
        guard text.count >= 24, text.split(whereSeparator: \.isWhitespace).count >= 5 else {
            return FolderClassificationResult(status: .insufficientContent, reason: "More meeting content is needed to choose a folder.")
        }
        guard Set(candidates.map { $0.folder.id }).count == candidates.count else {
            return FolderClassificationResult(status: .ambiguous, reason: "Folder identities are ambiguous. Refresh the library.")
        }
        var texts = [text]
        var ranges: [Range<Int>] = []
        for candidate in candidates {
            let start = texts.count
            texts.append(candidate.folder.name + ". " + String(candidate.folder.description.prefix(1_000)))
            texts += candidate.manualExamples.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(5).map { String($0.prefix(1_200)) }
            ranges.append(start..<texts.count)
        }
        do {
            guard let vectors = try await embeddingProvider.embeddings(for: texts), vectors.count == texts.count,
                  let query = vectors.first, !query.isEmpty,
                  vectors.allSatisfy({ $0.count == query.count && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else {
                return FolderClassificationResult(status: .modelUnavailable, reason: "An installed sentence model is unavailable for this language or content. File this meeting manually.")
            }
            try Task.checkCancellation()
            let queryNorm = sqrt(query.reduce(0) { $0 + $1 * $1 })
            var ranked: [(id: String, similarity: Double)] = []
            for (index, range) in ranges.enumerated() {
                let score = range.map { offset in
                    let vector = vectors[offset]
                    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
                    return zip(query, vector).reduce(0) { $0 + $1.0 * $1.1 } / (queryNorm * norm)
                }.max() ?? -1
                guard score.isFinite else { return FolderClassificationResult(status: .modelUnavailable, reason: "The sentence model returned unusable embeddings. File this meeting manually.") }
                ranked.append((candidates[index].folder.id, min(1, max(-1, score))))
            }
            ranked.sort { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity }
            let best = ranked[0]
            let margin = ranked.count > 1 ? best.similarity - ranked[1].similarity : best.similarity
            guard best.similarity >= minimumSimilarity else {
                return FolderClassificationResult(status: .unrelated, reason: "No folder is a strong semantic match. Add a description or file it manually.", similarity: best.similarity, margin: margin)
            }
            guard margin >= minimumMargin else {
                return FolderClassificationResult(status: .ambiguous, reason: "Several folders are too similar to choose safely. File this meeting manually.", similarity: best.similarity, margin: margin)
            }
            return FolderClassificationResult(folderID: best.id, status: .matched, reason: "A strong semantic match is clearly separated from the other folders.", similarity: best.similarity, margin: margin)
        } catch {
            return FolderClassificationResult(status: .modelUnavailable, reason: "Local folder classification could not complete. Your meeting is unchanged.")
        }
    }
}
