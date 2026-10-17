import Foundation
import Testing
import MinutesCore
@testable import MinutesSummarize

private actor FolderVectorsFixture: FolderSemanticEmbeddingProvider {
    let values: [[Double]]?
    private var calls: [[String]] = []
    init(_ values: [[Double]]?) { self.values = values }
    func embeddings(for texts: [String]) async throws -> [[Double]]? { calls.append(texts); return values }
    func requested() -> [[String]] { calls }
}

struct FolderClassifierTests {
    private let input = FolderClassificationInput(title: "Quarterly financial planning", summary: "We reviewed operating expenses and the next budget.")
    @Test("Folder CLI validates destinations and rejects unrelated or unknown flags")
    func commandValidation() throws {
        let move = try FolderCommandOptions(arguments: ["move", "meeting", "--unfiled", "--data-dir", "/tmp/fixture"])
        #expect(move.action == .move && move.targetID == "meeting" && move.folderID == nil)
        let classify = try FolderCommandOptions(arguments: ["classify", "meeting", "--apply"])
        #expect(classify.apply)
        for invalid in [["move", "meeting"], ["move", "meeting", "--folder", "a", "--unfiled"], ["create", "--description", "missing name"], ["delete", "a", "--apply"], ["classify", "meeting", "--cloud"], ["update", "a"], ["list", "unexpected"]] {
            #expect(throws: FolderCommandUsage.self) { try FolderCommandOptions(arguments: invalid) }
        }
    }
    @Test("Every folder is compared and the winning identity survives renamed labels")
    func allFoldersAndStableIdentity() async {
        let folders = (0..<20).map { FolderClassificationCandidate(folder: MeetingFolder(id: "folder-\($0)", name: "Category \($0)", description: "Description \($0)")) }
        let fixture = FolderVectorsFixture([[1,0]] + Array(repeating: [0,1], count: 19) + [[1,0]])
        let result = await FolderClassifier(embeddingProvider: fixture).classify(input: input, candidates: folders)
        #expect(result.status == .matched && result.folderID == "folder-19")
        let calls = await fixture.requested()
        #expect(calls.count == 1 && calls[0].count == 21)
    }
    @Test("Ambiguous, unrelated, malformed and absent embeddings abstain")
    func abstainsWithoutReliableSeparation() async {
        let folders = ["a", "b"].map { FolderClassificationCandidate(folder: MeetingFolder(id: $0, name: $0)) }
        let ambiguous = await FolderClassifier(embeddingProvider: FolderVectorsFixture([[1,0],[1,0.1],[1,0.11]])).classify(input: input, candidates: folders)
        #expect(ambiguous.status == .ambiguous && ambiguous.folderID == nil)
        let unrelated = await FolderClassifier(embeddingProvider: FolderVectorsFixture([[1,0],[0,1],[-1,0]])).classify(input: input, candidates: folders)
        #expect(unrelated.status == .unrelated && unrelated.folderID == nil)
        for bad in [nil, [[1.0,0],[Double.nan,0],[0,1]], [[0.0,0],[1,0],[0,1]], [[1.0,0],[1],[0,1]]] as [[[Double]]?] {
            let result = await FolderClassifier(embeddingProvider: FolderVectorsFixture(bad)).classify(input: input, candidates: folders)
            #expect(result.status == .modelUnavailable && result.folderID == nil)
        }
    }
    @Test("Manual examples are bounded and empty content never invokes the model")
    func boundedExamplesAndEmptyInput() async {
        let candidate = FolderClassificationCandidate(folder: MeetingFolder(id: "work", name: "Work"), manualExamples: (0..<20).map { "Manual example \($0)" })
        let fixture = FolderVectorsFixture([[1,0]] + Array(repeating: [1,0], count: 6))
        let result = await FolderClassifier(embeddingProvider: fixture).classify(input: input, candidates: [candidate])
        #expect(result.status == .matched)
        #expect(await fixture.requested().first?.count == 7)
        let emptyFixture = FolderVectorsFixture(nil)
        let empty = await FolderClassifier(embeddingProvider: emptyFixture).classify(input: FolderClassificationInput(title: "Quick meeting"), candidates: [candidate])
        #expect(empty.status == .insufficientContent)
        #expect(await emptyFixture.requested().isEmpty)
    }
}

@Suite("Installed sentence model folder acceptance", .serialized)
struct NativeFolderClassifierTests {
    private let candidates = [
        FolderClassificationCandidate(folder: MeetingFolder(id: "finance", name: "Finance", description: "Budgets, invoices, cash flow, accounting, spending and financial planning.")),
        FolderClassificationCandidate(folder: MeetingFolder(id: "engineering", name: "Product engineering", description: "Software releases, application defects, testing, architecture and delivery plans.")),
        FolderClassificationCandidate(folder: MeetingFolder(id: "people", name: "People", description: "Hiring interviews, employee growth, team staffing and performance conversations.")),
        FolderClassificationCandidate(folder: MeetingFolder(id: "customers", name: "Customers", description: "Client onboarding, customer support, account renewals and service feedback."))
    ]
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_MODELS"] == "1"))
    func actualModelPrecisionAndManualExamples() async throws {
        let provider = NaturalLanguageFolderEmbeddingProvider()
        guard try await provider.embeddings(for: ["A fictional financial planning meeting about budgets and invoices."]) != nil else {
            print("FOLDER_FIXTURE_MODEL_UNAVAILABLE: no installed sentence embedding; classifier abstains")
            return
        }
        let classifier = FolderClassifier(embeddingProvider: provider)
        let finance = FolderClassificationInput(title: "Quarterly budget review", summary: "We reviewed operating expenses, cash reserves and vendor invoices. Finance will reconcile the missing payments before approving next quarter's spending plan.")
        let sparse = await classifier.classify(input: finance, candidates: candidates)
        print("FOLDER_FIXTURE_FINANCE_SPARSE: \(sparse.status) similarity=\(sparse.similarity ?? -1) margin=\(sparse.margin ?? -1)")
        #expect(sparse.folderID == nil)
        var examples = candidates
        examples[0] = FolderClassificationCandidate(folder: candidates[0].folder, manualExamples: ["Quarterly finance review. We reviewed vendor invoices, cash flow and operating expenses, then approved next quarter's budget and spending plan."])
        let learned = await classifier.classify(input: finance, candidates: examples)
        print("FOLDER_FIXTURE_FINANCE_MANUAL: \(learned.status) similarity=\(learned.similarity ?? -1) margin=\(learned.margin ?? -1)")
        #expect(learned.folderID == "finance" && learned.status == .matched)
        let ambiguous = await classifier.classify(input: FolderClassificationInput(title: "Customer onboarding review", summary: "The new client needs help importing contacts and configuring account permissions. Support will schedule a training call and follow up on service feedback."), candidates: candidates)
        let unrelated = await classifier.classify(input: FolderClassificationInput(title: "Weekend garden plans", summary: "We are planting tomatoes and basil, watering the vegetable beds and choosing compost for the garden."), candidates: candidates)
        print("FOLDER_FIXTURE_CUSTOMERS: \(ambiguous.status); GARDEN: \(unrelated.status)")
        #expect(ambiguous.folderID == nil && unrelated.folderID == nil)
    }
}
