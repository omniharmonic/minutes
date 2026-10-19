import Foundation
import Speech
import AVFoundation
import os

public enum ASRError: Error, LocalizedError {
    case recognizerUnavailable(String)
    case authorizationDenied
    case missingUsageDescription
    case consentNeedsNormalAppLaunch
    case transcriptionFailed(String)
    case noSpeechDetected
    case recognitionTimedOut
    case audioUnreadable(String)
    
    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let msg):
            return "Speech recognizer unavailable: \(msg)"
        case .consentNeedsNormalAppLaunch:
            return "Open Minutes.app normally from Finder, then use Start Recording to grant Speech Recognition access. A direct command-line launch cannot request this permission safely. No recording has started."
        case .missingUsageDescription:
            return "This Minutes build is missing its Speech Recognition privacy description. Reopen the packaged Minutes app or install the rebuilt app; your audio is preserved."
        case .authorizationDenied:
            return "Speech recognition permission denied by user or system policy"
        case .noSpeechDetected:
            return "No speech was recognized in this audio window."
        case .recognitionTimedOut:
            return "On-device speech recognition stopped responding for this audio window."
        case .transcriptionFailed(let msg):
            return "Audio transcription failed: \(msg)"
        case .audioUnreadable(let msg):
            return "Audio unreadable: \(msg)"
        }
    }
}

extension ASRError {
    /// Affects one audio window only; other windows and shorter retries continue.
    var isWindowLevelMiss: Bool {
        switch self {
        case .noSpeechDetected, .recognitionTimedOut: return true
        default: return false
        }
    }
}

public final class ASRService: Sendable {
    public let locale: Locale
    
    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }
    
    /// Transcribes an audio file on-device using Speech framework, returning timed words.
    public func transcribe(
        audioURL: URL,
        fallbackTranscriptURL: URL? = nil
    ) async throws -> [ASRWord] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ASRError.audioUnreadable("File does not exist at \(audioURL.path)")
        }
        
        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            throw ASRError.audioUnreadable("Audio file is 0 bytes")
        }
        
        if fallbackTranscriptURL != nil {
            throw ASRError.transcriptionFailed("Plain text has no verified audio timestamps. Use minutes-cli import-transcript to import it without timing.")
        }
        if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
            return try await performRecognition(recognizer: recognizer, audioURL: audioURL)
        }

        throw ASRError.recognizerUnavailable("SFSpeechRecognizer not available for locale \(locale.identifier)")
    }
    
    public static func validateConsentLaunch(isAppBundle: Bool, parentPID: Int32) throws {
        guard isAppBundle && parentPID == 1 else { throw ASRError.consentNeedsNormalAppLaunch }
    }

    public static func validateSpeechUsageDescription(_ description: String?) throws {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRError.missingUsageDescription
        }
    }

    /// Explicit setup preflight. This never starts recording or uploads audio.
    public func prepareForRecording() async throws {
        try Self.validateSpeechUsageDescription(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String)
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            #if os(macOS)
            // TCC attributes direct child processes to their hosting app, even
            // when both Mach-O and Bundle.main have valid usage descriptions.
            // Request consent only from a normally LaunchServices-launched app.
            try Self.validateConsentLaunch(isAppBundle: Bundle.main.bundleURL.pathExtension == "app", parentPID: getppid())
            #endif
        }
        try await Self.requireAuthorization {
            if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return false }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw ASRError.recognizerUnavailable("Install/enable on-device speech recognition for \(locale.identifier) in macOS/iOS settings before recording.")
        }
    }

    // Fail closed: unsupported local speech must never send meeting audio to Apple.
    static func localRecognitionRequest(audioURL: URL, supportsOnDeviceRecognition: Bool) throws -> SFSpeechURLRecognitionRequest {
        guard supportsOnDeviceRecognition else {
            throw ASRError.recognizerUnavailable("On-device recognition is unsupported for this locale or device")
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        return request
    }

    static func requireAuthorization(_ authorize: @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw ASRError.authorizationDenied }
    }

    static func classifyRecognitionError(_ error: NSError) -> ASRError {
        // Assistant error numbers are not a stable public contract. Keep the
        // observed compatibility case exact and log only domain/code so future
        // OS behavior can be verified without recording speech or error userInfo.
        Logger(subsystem: "app.minutes", category: "SpeechRecognition").error(
            "Recognition failure domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
        if error.domain == "kAFAssistantErrorDomain", error.code == 1110 { return .noSpeechDetected }
        return .transcriptionFailed(error.localizedDescription)
    }

    private func performRecognition(recognizer: SFSpeechRecognizer, audioURL: URL) async throws -> [ASRWord] {
        try Self.validateSpeechUsageDescription(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String)
        let request = try Self.localRecognitionRequest(
            audioURL: audioURL, supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
        // Batch processing must never trigger a privacy prompt after recording.
        // Preflight obtains consent before capture; denied/missing consent keeps
        // the saved file available for retry instead of asking TCC from a worker.
        try await Self.requireAuthorization { SFSpeechRecognizer.authorizationStatus() == .authorized }

        let state = AtomicRecognitionState()
        // Apple's local recognizer can stop calling back (for example when its XPC
        // service is reclaimed). Without a deadline the whole meeting waits forever.
        let deadline = Self.recognitionDeadline(audioURL: audioURL)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(deadline))
            state.cancel()
            state.resumeOnce(throwing: ASRError.recognitionTimedOut)
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            state.setContinuation(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    state.resumeOnce(throwing: Self.classifyRecognitionError(error as NSError))
                    return
                }
                
                guard let result = result else { return }
                
                if result.isFinal {
                    var words: [ASRWord] = []
                    for seg in result.bestTranscription.segments {
                        let word = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !word.isEmpty {
                            words.append(ASRWord(
                                word: word,
                                start: seg.timestamp,
                                end: seg.timestamp + max(0.05, seg.duration),
                                confidence: Double(seg.confidence)
                            ))
                        }
                    }
                    state.resumeOnce(returning: words)
                }
            }
            state.setTask(task, recognizer: recognizer)
            }
        } onCancel: {
            state.cancel()
            state.resumeOnce(throwing: CancellationError())
        }
    }

    /// Generous: Speech normally finishes a 20-second window in well under 5 seconds.
    static func recognitionDeadline(audioURL: URL) -> Double {
        let duration = (try? AVAudioFile(forReading: audioURL)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 20
        return max(30, duration * 3)
    }
    
}

final class AtomicRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false
    private var task: SFSpeechRecognitionTask?
    // Retained for the request's lifetime; a deallocated recognizer may never call back.
    private var recognizer: SFSpeechRecognizer?
    private var continuation: CheckedContinuation<[ASRWord], Error>?
    // A deadline or cancellation can fire before the continuation exists.
    private var pendingError: Error?

    func setContinuation(_ c: CheckedContinuation<[ASRWord], Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let pendingError, !isResumed {
            isResumed = true
            c.resume(throwing: pendingError)
        } else {
            continuation = c
        }
    }

    func setTask(_ t: SFSpeechRecognitionTask, recognizer: SFSpeechRecognizer) {
        lock.lock()
        defer { lock.unlock() }
        self.task = t
        self.recognizer = recognizer
        if isResumed { t.cancel() }
    }
    
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
    }
    
    func resumeOnce(returning value: [ASRWord]) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed, let continuation else { return }
        isResumed = true
        self.continuation = nil
        recognizer = nil
        continuation.resume(returning: value)
    }
    
    func resumeOnce(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        guard let continuation else { pendingError = pendingError ?? error; return }
        isResumed = true
        self.continuation = nil
        recognizer = nil
        continuation.resume(throwing: error)
    }
}

