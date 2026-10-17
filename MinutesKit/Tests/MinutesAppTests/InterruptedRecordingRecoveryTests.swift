import Foundation
import Testing
import SQLite3
import MinutesCore
import MinutesSpeech
@testable import MinutesApp

@MainActor
struct InterruptedRecordingRecoveryTests {
    @Test("Relaunch marks abandoned captures interrupted without touching audio or starting work")
    func relaunchPreservesCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-interrupted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        let audio = directory.appendingPathComponent("partial.wav")
        let prefix = Data([82, 73, 70, 70, 1, 2, 3, 4]) // Deliberately incomplete; recovery must not certify it.
        try prefix.write(to: audio)
        do {
            let store = try MinutesStore(dbPath: path)
            for status in ["starting", "recording", "recorded", "needs_review", "failed", "processing"] {
                try store.saveMeeting(Meeting(id: status, title: status, status: status, audioPath: audio.path))
            }
        }
        let store = try MinutesStore(dbPath: path)
        var starts = 0
        let state = try AppState(store: store, audioDirectory: directory,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in starts += 1 }, captureStop: { nil },
            processAudio: { _, _, _ in Issue.record("Recovery must never process automatically"); throw CancellationError() })
        #expect(starts == 0 && !state.isRecording && !state.isProcessing)
        #expect(state.activeRecordingMeetingID == nil)
        #expect(state.statusMessage.localizedCaseInsensitiveContains("interrupted"))
        for status in ["starting", "recording"] {
            let meeting = try #require(store.getMeeting(id: status))
            #expect(meeting.status == "interrupted")
            #expect(meeting.audioPath == audio.path && meeting.endedAt == nil)
        }
        for status in ["recorded", "needs_review", "failed", "processing"] {
            #expect(store.getMeeting(id: status)?.status == status)
        }
        #expect(try Data(contentsOf: audio) == prefix)
        #expect(try store.markAbandonedRecordingsInterrupted() == 0)
        // Normal refresh must not mistake the current process's capture for an orphan.
        state.startQuickMeeting()
        let activeID = try #require(state.activeRecordingMeetingID)
        state.loadInitialData()
        #expect(store.getMeeting(id: activeID)?.status == "recording")
        #expect(state.isRecording && starts == 1)
    }
    @Test("Explicit processing repairs only a copy and retains it when transcription fails")
    func manualRecoveryIsExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-recovery-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("meeting_fixture.wav")
        let bytes = incompletePCM()
        try bytes.write(to: original)
        let store = try MinutesStore(dbPath: directory.appendingPathComponent("db.sqlite").path)
        try store.saveMeeting(Meeting(id: "fixture", title: "Fixture", status: "recording", audioPath: original.path))
        let state = try AppState(store: store, audioDirectory: directory,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in Issue.record("Must not capture during recovery") }, captureStop: { nil },
            processAudio: { _, url, _ in
                #expect(url != original)
                #expect(try AudioDecoder.decode(fileURL: url, targetSampleRate: 16_000).samples.count == 16_000)
                throw CancellationError()
            })
        #expect(store.getMeeting(id: "fixture")?.audioPath == original.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("recovered") }.isEmpty)
        state.selectMeeting(id: "fixture")
        await state.processCurrentMeeting()
        let meeting = try #require(store.getMeeting(id: "fixture"))
        #expect(meeting.status == "recorded")
        let copy = try #require(meeting.audioPath)
        #expect(copy != original.path && FileManager.default.fileExists(atPath: copy))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(state.statusMessage.contains("Audio preserved"))
    }

    @Test("Failed persistence keeps interrupted recovery retryable until the copy path is saved")
    func failedCopyPathPersistenceRemainsInterrupted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-recovery-sql-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("meeting_fixture.wav")
        let bytes = incompletePCM()
        try bytes.write(to: original)
        let databasePath = directory.appendingPathComponent("db.sqlite").path
        let store = try MinutesStore(dbPath: databasePath)
        try store.saveMeeting(Meeting(id: "fixture", title: "Fixture", status: "interrupted", audioPath: original.path))
        var database: OpaquePointer?
        try #require(sqlite3_open(databasePath, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "CREATE TRIGGER reject_processing BEFORE UPDATE ON meeting WHEN NEW.status = 'processing' BEGIN SELECT RAISE(ABORT, 'fixture save failure'); END", nil, nil, nil) == SQLITE_OK)
        let calls = RecoveryProcessingCalls()
        let state = try AppState(store: store, audioDirectory: directory,
            recordingModelReadiness: { (true, "Ready") }, captureStart: { _ in Issue.record("Must not capture") }, captureStop: { nil },
            processAudio: { _, url, _ in
                await calls.record(url)
                #expect(try AudioDecoder.decode(fileURL: url, targetSampleRate: 16_000).samples.count == 16_000)
                throw CancellationError()
            })
        state.selectMeeting(id: "fixture")
        await state.processCurrentMeeting()
        let failedSave = try #require(store.getMeeting(id: "fixture"))
        #expect(failedSave.status == "interrupted")
        #expect(failedSave.audioPath == original.path)
        #expect(await calls.urls.isEmpty)
        try #require(sqlite3_exec(database, "DROP TRIGGER reject_processing", nil, nil, nil) == SQLITE_OK)
        await state.processCurrentMeeting()
        let retry = try #require(store.getMeeting(id: "fixture"))
        #expect(retry.status == "recorded")
        let urls = await calls.urls
        #expect(urls.count == 1)
        #expect(retry.audioPath == urls.first?.path)
        #expect(retry.audioPath != original.path)
        #expect(try Data(contentsOf: original) == bytes)
    }

    private func incompletePCM() -> Data {
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        text("RIFF"); u32(36); text("WAVE"); text("fmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(0)
        bytes.append(Data(count: 32_000))
        return bytes
    }

}


private actor RecoveryProcessingCalls {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
