import Foundation
import AVFoundation

/// Timed input to the disposable preview only. Never opens an audio output or input device.
@MainActor public enum CaptionFileFixture {
    public static func feed(url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(max(1, file.processingFormat.sampleRate / 10))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw ASRError.audioUnreadable("Cannot allocate fixture buffer") }
            try file.read(into: buffer)
            CaptionAudioFeed.shared.offer(buffer, source: "File preview")
            try await Task.sleep(for: .milliseconds(100))
        }
        // Allow pending local recognition to deliver its final partial.
        try await Task.sleep(for: .seconds(2))
    }
}
