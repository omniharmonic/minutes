#if os(macOS)
import Foundation
import CoreMedia
import ScreenCaptureKit
import Testing
@testable import MinutesSpeech

@Suite("Screen capture callback readiness")
struct CaptureCallbackTests {
    @Test("Unavailable startup callbacks do not poison the recording archive")
    func skipsUnavailableCallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("callback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SynchronizedCaptureArchive(directory: root, includeMicrophone: true)
        let output = CaptureStreamOutput(archive: archive)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        #expect(status == noErr)
        let buffer = try #require(sample)
        output.handleSampleBuffer(buffer, type: .microphone)
        #expect(archive.errorDescription == nil)
        CMSampleBufferInvalidate(buffer)
        output.handleSampleBuffer(buffer, type: .audio)
        #expect(archive.errorDescription == nil)
    }
}
#endif
