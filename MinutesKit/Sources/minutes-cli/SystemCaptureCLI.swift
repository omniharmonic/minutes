import Foundation
import MinutesCore
import MinutesSpeech
#if os(macOS)
import Darwin
#endif

@MainActor enum SystemCaptureCLI {
    /// arguments excludes the command name. Only this explicit command opens capture devices.
    static func run(arguments: [String]) async throws {
        let options = try SystemCaptureOptions(arguments: arguments)
        #if os(macOS)
        guard !FileManager.default.fileExists(atPath: options.directory.path) else {
            throw NSError(domain: "Minutes.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a new output directory. Existing recordings are never overwritten."])
        }
        if options.requestPermission {
            guard await PermissionManager.shared.requestSystemAudioAccess() else {
                throw NSError(domain: "Minutes.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen & System Audio Recording access was not granted. Restart the CLI if macOS requests it."])
            }
            if options.includeMicrophone {
                guard await PermissionManager.shared.requestMicrophoneAccess() else {
                    throw NSError(domain: "Minutes.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access was not granted."])
                }
            }
        }
        let capture = SystemAudioCaptureService()
        try await capture.startRecording(to: options.directory, includeMicrophone: options.includeMicrophone)
        print("Recording system audio\(options.includeMicrophone ? " + microphone" : "") for up to \(options.seconds) seconds. Ctrl-C stops and finalizes the preserved source tracks.")
        let interrupts = AsyncStream<Void>.makeStream()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { interrupts.continuation.yield(()) }
        source.resume()
        defer { source.cancel(); interrupts.continuation.finish(); signal(SIGINT, SIG_DFL) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: .seconds(options.seconds)) }
            group.addTask { for await _ in interrupts.stream { break } }
            group.addTask {
                while !Task.isCancelled {
                    if await capture.captureError != nil { return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
        let result = try await capture.stopRecording()
        guard let processing = result.processingURL else {
            throw CaptureFinalizationError(result: result)
        }
        print("Source tracks and timing manifest: \(result.directory.path)")
        print("Processing audio: \(processing.path)")
        #else
        throw NSError(domain: "Minutes.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "System capture requires macOS 15 or later. Microphone recording remains available on iOS."])
        #endif
    }
}
