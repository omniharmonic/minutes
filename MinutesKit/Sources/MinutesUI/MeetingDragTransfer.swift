#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import Foundation
import os

enum MeetingDragError: Error, LocalizedError, Sendable {
    case invalidPayload, unavailableData, unknownMeeting
    var errorDescription: String? {
        switch self {
        case .invalidPayload: "This drop does not contain a valid Minutes meeting."
        case .unavailableData: "The meeting could not be read from this drag. Try again or use Move to Folder."
        case .unknownMeeting: "A dragged meeting is no longer in this library. Nothing was moved."
        }
    }
}
enum MeetingDragPayload {
    private struct Envelope: Codable { let version: Int; let meetingIDs: [String] }
    static let prefix = "minutes-meetings:v1:"
    private static func check(_ ids: [String]) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !ids.isEmpty, ids.count <= 100, ids.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 256 && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw MeetingDragError.invalidPayload }
    }
    static func encode(_ ids: [String]) throws -> Data {
        try check(ids)
        return try JSONEncoder().encode(Envelope(version: 1, meetingIDs: ids))
    }
    static func text(_ data: Data) -> Data { Data((prefix + data.base64EncodedString()).utf8) }
    static func decode(_ data: Data, plainText: Bool) throws -> [String] {
        guard data.count <= 65_536 else { throw MeetingDragError.invalidPayload }
        var payload = data
        if plainText {
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix),
                  let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { throw MeetingDragError.invalidPayload }
            payload = decoded
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: payload), envelope.version == 1 else {
            throw MeetingDragError.invalidPayload
        }
        try check(envelope.meetingIDs)
        return envelope.meetingIDs
    }
    static func validated(_ ids: [String], knownIDs: Set<String>) throws -> [String] {
        try check(ids)
        guard ids.allSatisfy(knownIDs.contains) else { throw MeetingDragError.unknownMeeting }
        return Array(Set(ids)).sorted()
    }
}

public enum MeetingDragTransfer {
    public static let contentType = UTType(exportedAs: "app.minutes.meeting-identifiers", conformingTo: .data)
    static let supportedTypes = [contentType, UTType.plainText]
    private static let logger = Logger(subsystem: "app.minutes", category: "MeetingDrag")

    public static func provider(meetingID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? MeetingDragPayload.encode([meetingID]) else {
            logger.error("sourceRejected")
            return provider
        }
        provider.suggestedName = "Meeting"
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        let text = MeetingDragPayload.text(data)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(text, nil); return nil
        }
        logger.notice("sourceBegin")
        return provider
    }

    /// Starts every provider load synchronously from performDrop, not from a
    /// validation/hover callback. Completion returns to MainActor only after ALL
    /// payloads decode, so callers can validate fresh state and commit one batch.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor @Sendable (Result<[String], MeetingDragError>) -> Void) {
        guard !providers.isEmpty, providers.count <= 100 else {
            Task { @MainActor in completion(.failure(.invalidPayload)) }; return
        }
        let collector = MeetingDropCollector(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            let custom = provider.hasItemConformingToTypeIdentifier(contentType.identifier)
            let type = custom ? contentType.identifier : UTType.plainText.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else {
                collector.receive(index, .failure(.invalidPayload)); continue
            }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                guard error == nil, let data else { collector.receive(index, .failure(.unavailableData)); return }
                do { collector.receive(index, .success(try MeetingDragPayload.decode(data, plainText: !custom))) }
                catch { collector.receive(index, .failure(.invalidPayload)) }
            }
        }
    }
}

private final class MeetingDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[String], MeetingDragError>?]
    private var finished = false
    private let completion: @MainActor @Sendable (Result<[String], MeetingDragError>) -> Void
    init(count: Int, completion: @escaping @MainActor @Sendable (Result<[String], MeetingDragError>) -> Void) {
        results = Array(repeating: nil, count: count); self.completion = completion
    }
    func receive(_ index: Int, _ result: Result<[String], MeetingDragError>) {
        let completed: Result<[String], MeetingDragError>? = lock.withLock {
            guard !finished, results[index] == nil else { return nil }
            results[index] = result
            guard results.allSatisfy({ $0 != nil }) else { return nil }
            finished = true
            var ids: [String] = []
            for item in results {
                switch item! {
                case .failure(let error): return .failure(error)
                case .success(let values): ids += values
                }
            }
            guard ids.count <= 100 else { return .failure(.invalidPayload) }
            return .success(ids)
        }
        if let completed { Task { @MainActor in completion(completed) } }
    }
}

@MainActor
private struct MeetingFolderDropDelegate: DropDelegate {
    let enabled: Bool
    let targeted: Binding<Bool>
    let knownIDs: () -> Set<String>
    let move: ([String]) throws -> Void
    let onError: (Error) -> Void
    private let logger = Logger(subsystem: "app.minutes", category: "MeetingDrag")
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: MeetingDragTransfer.supportedTypes) }
    func dropEntered(info: DropInfo) {
        targeted.wrappedValue = validateDrop(info: info)
        if targeted.wrappedValue { logger.notice("targetEntered") }
    }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: MeetingDragTransfer.supportedTypes)
        guard !providers.isEmpty, providers.count <= 100 else { return false }
        logger.notice("dropScheduled providers=\(providers.count, privacy: .public)")
        MeetingDragTransfer.load(providers) { result in
            do {
                let ids = try MeetingDragPayload.validated(result.get(), knownIDs: knownIDs())
                try move(ids) // Same MainActor turn, one atomic database operation.
                logger.notice("dropCommitted items=\(ids.count, privacy: .public)")
            } catch {
                logger.error("dropRejected")
                onError(error)
            }
        }
        return true // Accepted for asynchronous loading, not a claim of DB success.
    }
}

@MainActor
private struct MeetingFolderDropModifier: ViewModifier {
    let enabled: Bool
    let knownIDs: () -> Set<String>
    let move: ([String]) throws -> Void
    let onError: (Error) -> Void
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background { if targeted { RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.18)) } }
            .onDrop(of: MeetingDragTransfer.supportedTypes, delegate: MeetingFolderDropDelegate(
                enabled: enabled, targeted: $targeted, knownIDs: knownIDs, move: move, onError: onError))
    }
}

@MainActor
public extension View {
    func meetingFolderDropTarget(enabled: Bool = true, knownIDs: @escaping () -> Set<String>,
                                 move: @escaping ([String]) throws -> Void, onError: @escaping (Error) -> Void) -> some View {
        modifier(MeetingFolderDropModifier(enabled: enabled, knownIDs: knownIDs, move: move, onError: onError))
    }
}
#endif
