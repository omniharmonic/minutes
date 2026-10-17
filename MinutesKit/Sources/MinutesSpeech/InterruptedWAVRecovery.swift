import Foundation

/// Repairs only Minutes' interrupted PCM microphone container, never the source.
/// This does not certify speech, recording completeness, or any transcription.
public enum InterruptedWAVRecovery {
    public static func makeCopy(original: URL, meetingID: String, managedAudioDirectory: URL) throws -> URL {
        func invalid() -> NSError {
            NSError(domain: "MinutesAudioRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The interrupted audio has an unsupported or incomplete format. The original file is preserved."])
        }
        let expected = managedAudioDirectory.appendingPathComponent("meeting_\(meetingID).wav").standardizedFileURL
        guard original.standardizedFileURL == expected,
              original.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath() else { throw invalid() }
        let properties = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw invalid() }
        let input = try FileHandle(forReadingFrom: original)
        defer { try? input.close() }
        let actualLength = try input.seekToEnd()
        guard actualLength > 44, actualLength <= UInt64(UInt32.max) + 8 else { throw invalid() }
        let size = Int(actualLength)
        try input.seek(toOffset: 0)
        let header = try input.read(upToCount: min(size, 65_536)) ?? Data()
        func tag(_ index: Int) -> String { String(decoding: header[index..<index + 4], as: UTF8.self) }
        func u16(_ index: Int) -> UInt16 { UInt16(header[index]) | UInt16(header[index + 1]) << 8 }
        func u32(_ index: Int) -> UInt32 {
            UInt32(header[index]) | UInt32(header[index + 1]) << 8 | UInt32(header[index + 2]) << 16 | UInt32(header[index + 3]) << 24
        }
        guard header.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE",
              UInt64(u32(4)) + 8 <= UInt64(size) else { throw invalid() }
        var cursor = 12
        var hasFormat = false
        var dataHeader: Int?
        for _ in 0..<32 {
            guard cursor <= header.count - 8 else { throw invalid() }
            let kind = tag(cursor)
            let length = Int(u32(cursor + 4))
            let payload = cursor + 8
            if kind == "data" {
                let available = size - payload
                guard hasFormat, available > 0, available % 2 == 0,
                      length == 0 || length == available else { throw invalid() }
                dataHeader = cursor
                break
            }
            guard length <= header.count - payload else { throw invalid() }
            if kind == "fmt " {
                guard !hasFormat, length == 16, u16(payload) == 1, u16(payload + 2) == 1,
                      u32(payload + 4) == 16_000, u32(payload + 8) == 32_000,
                      u16(payload + 12) == 2, u16(payload + 14) == 16 else { throw invalid() }
                hasFormat = true
            } else {
                guard kind == "JUNK" || kind == "FLLR" else { throw invalid() }
            }
            cursor = payload + length + length % 2
        }
        guard let dataHeader else { throw invalid() }
        let destination = original.deletingLastPathComponent().appendingPathComponent(
            "meeting_\(meetingID).recovered-\(UUID().uuidString.lowercased()).wav")
        try FileManager.default.copyItem(at: original, to: destination)
        do {
            // Copying and patching uses bounded memory; never load the audio payload.
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            guard try output.seekToEnd() == actualLength, try input.seekToEnd() == actualLength else { throw invalid() }
            func writeSize(_ value: UInt32, at offset: UInt64) throws {
                var little = value.littleEndian
                try output.seek(toOffset: offset)
                try withUnsafeBytes(of: &little) { try output.write(contentsOf: $0) }
            }
            try writeSize(UInt32(size - 8), at: 4)
            try writeSize(UInt32(size - dataHeader - 8), at: UInt64(dataHeader + 4))
            try output.synchronize()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
