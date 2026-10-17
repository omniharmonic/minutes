import Foundation
import Testing
@testable import MinutesSpeech

struct InterruptedWAVRecoveryTests {
    private func fixture(sampleRate: UInt32 = 16_000) -> Data {
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        text("RIFF"); u32(4088); text("WAVE"); text("JUNK"); u32(28); bytes.append(Data(count: 28))
        text("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("FLLR"); u32(4008); bytes.append(Data(count: 4008)); text("data"); u32(0)
        bytes.append(Data(count: 32_000))
        return bytes
    }

    @Test("Interrupted Apple WAV header is repaired in a distinct readable copy with original unchanged")
    func recoverKnownLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("meeting_fixture.wav")
        let bytes = fixture()
        try bytes.write(to: original)
        let copy = try InterruptedWAVRecovery.makeCopy(original: original, meetingID: "fixture", managedAudioDirectory: root)
        #expect(copy != original)
        #expect(try Data(contentsOf: original) == bytes)
        let decoded = try AudioDecoder.decode(fileURL: copy, targetSampleRate: 16_000)
        #expect(decoded.samples.count == 16_000)
    }

    @Test("Recovery rejects foreign formats and paths without creating copies")
    func rejectUnknownFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("meeting_fixture.wav")
        try fixture(sampleRate: 48_000).write(to: original)
        #expect(throws: (any Error).self) { try InterruptedWAVRecovery.makeCopy(original: original, meetingID: "fixture", managedAudioDirectory: root) }
        try fixture().write(to: original)
        #expect(throws: (any Error).self) { try InterruptedWAVRecovery.makeCopy(original: original, meetingID: "other", managedAudioDirectory: root) }
        var malformed = fixture(); malformed.removeLast()
        try malformed.write(to: original)
        #expect(throws: (any Error).self) { try InterruptedWAVRecovery.makeCopy(original: original, meetingID: "fixture", managedAudioDirectory: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["meeting_fixture.wav"])
    }
}
