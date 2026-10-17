import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MinutesUI

struct MeetingDragPayloadTests {
    @Test("Branded native and plain-text payloads round-trip IDs without accepting arbitrary text")
    func brandedPayloadOnly() throws {
        let ids = ["meeting-one", "meeting-two"]
        let data = try MeetingDragPayload.encode(ids)
        #expect(try MeetingDragPayload.decode(data, plainText: false) == ids)
        #expect(try MeetingDragPayload.decode(MeetingDragPayload.text(data), plainText: true) == ids)
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.decode(Data("meeting-one".utf8), plainText: true) }
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.decode(Data("{\"version\":99,\"meetingIDs\":[\"meeting-one\"]}".utf8), plainText: false) }
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.decode(Data(repeating: 1, count: 65_537), plainText: false) }
    }
    @Test("Every dropped ID must still exist before any atomic move is requested")
    func validateWholeDrop() throws {
        #expect(try MeetingDragPayload.validated(["one", "two", "one"], knownIDs: ["one", "two"]) == ["one", "two"])
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.validated(["one", "missing"], knownIDs: ["one"]) }
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.validated([], knownIDs: ["one"]) }
        #expect(throws: MeetingDragError.self) { try MeetingDragPayload.encode(["bad\nidentifier"]) }
    }
    @MainActor
    @Test("Native providers and branded plain text load as one batch; malformed providers reject the whole drop")
    func nativeProviderLoading() async throws {
        let first = MeetingDragTransfer.provider(meetingID: "one")
        let fallback = NSItemProvider()
        let data = MeetingDragPayload.text(try MeetingDragPayload.encode(["two"]))
        fallback.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        let loaded: Result<[String], MeetingDragError> = await withCheckedContinuation { continuation in
            MeetingDragTransfer.load([first, fallback]) { continuation.resume(returning: $0) }
        }
        #expect(try loaded.get() == ["one", "two"])
        let invalid = NSItemProvider()
        invalid.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("ordinary external text".utf8), nil); return nil
        }
        let rejected: Result<[String], MeetingDragError> = await withCheckedContinuation { continuation in
            MeetingDragTransfer.load([first, invalid]) { continuation.resume(returning: $0) }
        }
        if case .success = rejected { Issue.record("Mixed drop must not return a partial move") }
    }

}
