import Foundation
import Testing
@testable import MinutesSpeech

struct LocalRecognitionTests {
    @Test("Unavailable on-device speech fails before creating a cloud-capable request")
    func unsupportedLocalSpeechFailsClosed() {
        #expect(throws: ASRError.self) {
            try ASRService.localRecognitionRequest(audioURL: URL(fileURLWithPath: "/tmp/test.wav"), supportsOnDeviceRecognition: false)
        }
    }

    @Test("Supported speech requests explicitly require on-device recognition")
    func requestsAlwaysRequireLocalRecognition() throws {
        let request = try ASRService.localRecognitionRequest(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"), supportsOnDeviceRecognition: true)
        #expect(request.requiresOnDeviceRecognition)
        #expect(!request.shouldReportPartialResults)
    }
    @Test("Speech authorization denial blocks recognition")
    func authorizationDenialFails() async {
        await #expect(throws: ASRError.self) {
            try await ASRService.requireAuthorization { false }
        }
    }

}
