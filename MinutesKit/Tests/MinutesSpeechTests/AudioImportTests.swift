import Foundation
import AVFoundation
import Testing
import MinutesCore
@testable import MinutesSpeech

struct AudioImportTests {
    private func fixture() throws -> (URL, MinutesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MinutesStore(dbPath: root.appendingPathComponent("minutes.sqlite").path)
        let source = root.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        return (root, store, source)
    }

    @Test("Audio import persists a managed copy that survives deletion of its source")
    func managedAudioSurvives() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AudioImportService(store: store, audioDirectory: root.appendingPathComponent("audio"))
        let meeting = try service.importAudio(from: source, title: "Imported recording")
        let path = try #require(store.getMeeting(id: meeting.id)?.audioPath)
        #expect(path != source.path)
        try FileManager.default.removeItem(at: source)
        let decoded = try AudioDecoder.decode(fileURL: URL(fileURLWithPath: path))
        #expect(decoded.duration > 0)
        #expect(!decoded.samples.isEmpty)
        #expect(meeting.status == "recorded")
    }

    @Test("Corrupt audio cannot create a successful meeting record")
    func invalidAudioHasNoMeeting() throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("broken.wav")
        try Data("not a WAV".utf8).write(to: invalid)
        let service = AudioImportService(store: store, audioDirectory: root.appendingPathComponent("audio"))
        #expect(throws: (any Error).self) { try service.importAudio(from: invalid) }
        #expect(store.listMeetings().isEmpty)
    }

    @Test("Repeated imports do not overwrite each other's managed audio")
    func importsRemainDistinct() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AudioImportService(store: store, audioDirectory: root.appendingPathComponent("audio"))
        let first = try service.importAudio(from: source)
        let second = try service.importAudio(from: source)
        #expect(first.id != second.id)
        #expect(first.audioPath != second.audioPath)
        #expect(store.listMeetings().count == 2)
    }

    @Test("Plain text import has unknown timing and no synthetic speech vectors")
    func transcriptIsUntimed() throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("transcript.txt")
        try "Actual supplied transcript".write(to: source, atomically: true, encoding: .utf8)
        let service = AudioImportService(store: store, audioDirectory: root.appendingPathComponent("audio"))
        let meeting = try service.importTranscript(from: source)
        let utterances = store.listUtterances(meetingId: meeting.id)
        #expect(meeting.platform == "transcript_import")
        #expect(meeting.audioPath == nil)
        #expect(utterances.first?.start == 0)
        #expect(utterances.first?.end == 0)
        #expect(utterances.first?.words.isEmpty == true)
        #expect(store.listSpeakerClusters(meetingId: meeting.id).isEmpty)
        #expect(store.listVoiceprints().isEmpty)
    }
}
