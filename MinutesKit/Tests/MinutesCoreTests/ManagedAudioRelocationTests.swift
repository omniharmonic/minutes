import Foundation
import Testing
@testable import MinutesCore

struct ManagedAudioRelocationTests {
    @Test func reopeningRelocatesManagedAudioWithoutChangingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let file = audio.appendingPathComponent("meeting_test.wav")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: file)
        let path = root.appendingPathComponent("minutes.db").path
        do {
            let store = try MinutesStore(dbPath: path)
            try store.saveMeeting(Meeting(id: "test", title: "Test", status: "recorded", audioPath: "/old-container/Library/Application Support/Minutes/audio/meeting_test.wav"))
            try store.saveMeeting(Meeting(id: "external", title: "External", status: "recorded", audioPath: "/external/meeting_test.wav"))
            try store.saveMeeting(Meeting(id: "missing", title: "Missing", status: "recorded", audioPath: "/old-container/Library/Application Support/Minutes/audio/missing.wav"))
        }
        let reopened = try MinutesStore(dbPath: path)
        #expect(reopened.getMeeting(id: "test")?.audioPath == file.path)
        #expect(reopened.getMeeting(id: "external")?.audioPath == "/external/meeting_test.wav")
        #expect(reopened.getMeeting(id: "missing")?.audioPath?.hasPrefix("/old-container/") == true)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(reopened.getMeeting(id: "test")?.status == "recorded")
    }
}
