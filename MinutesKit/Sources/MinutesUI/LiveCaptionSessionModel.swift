import Foundation
import Combine
import MinutesCore
import MinutesSpeech
import Speech

/// Optional on-device live captions for a recording (used by iOS; the Mac
/// keeps its own caption panel). Captions are disposable previews: they never
/// touch the saved recording, the final transcript or voice profiles.
@MainActor
public final class LiveCaptionSessionModel: ObservableObject {
    public static let preferenceKey = "liveCaptionsEnabled"
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            preferences.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled { stop(status: "Live captions are off.") }
        }
    }
    @Published public private(set) var history = LiveCaptionHistory()
    @Published public private(set) var status = ""
    @Published public private(set) var isRunning = false
    /// Why captions were turned back off, shown next to the setting.
    @Published public private(set) var availabilityProblem: String?
    /// Latest caption text (partial or final), or nil when nothing was heard.
    public var latestText: String? { history.latestText }

    private let preferences: UserDefaults
    private let recognizer = LiveCaptionRecognizer()
    private var generation = UUID()
    private var finishing: Task<Void, Never>?

    public init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.isEnabled = preferences.bool(forKey: Self.preferenceKey)
    }

    /// Called when the person turns captions on: asks for Speech permission if
    /// it was never asked, and turns the setting back off (fail closed) when
    /// local recognition is not allowed or not supported on this device.
    public func confirmAvailability() async {
        guard isEnabled else { return }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard isEnabled else { return }
        availabilityProblem = Self.unavailableReason()
        if let problem = availabilityProblem {
            isEnabled = false
            status = problem
        }
    }

    /// Nil when on-device English recognition can run; otherwise why not.
    public static func unavailableReason() -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "Live captions need Speech Recognition permission. Allow it in Settings › Privacy & Security › Speech Recognition."
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            return "On-device English recognition is not available on this device, so live captions stay off. Recording is unaffected."
        }
        return nil
    }

    /// Starts local recognition for a new recording when captions are on.
    /// Unsupported or unauthorized recognition fails closed: no captions,
    /// recording continues, and nothing is ever sent to a server.
    public func begin() {
        guard isEnabled, !isRunning else { return }
        generation = UUID()
        history = LiveCaptionHistory()
        isRunning = true
        status = "Starting local captions…"
        let token = generation
        // The recognizer's finish() releases it at the end; a new session must
        // not start until the previous one has fully wound down.
        if let previous = finishing {
            Task { [weak self] in
                await previous.value
                guard let self, self.generation == token, self.isRunning else { return }
                self.startRecognizer(token: token)
            }
        } else {
            startRecognizer(token: token)
        }
    }

    private func startRecognizer(token: UUID) {
        do {
            try recognizer.start(update: { [weak self] id, text, source, final, order in
                guard let self, self.generation == token else { return }
                self.history.update(id: id, text: text, source: source, isFinal: final, order: order)
            }, notice: { [weak self] message in
                guard let self, self.generation == token, self.isRunning else { return }
                self.status = message
            })
            status = "Listening locally · preview may change"
        } catch {
            isRunning = false
            status = "Live captions unavailable: \(error.localizedDescription)"
        }
    }

    /// Lets the recognizer deliver its last words, then marks history final.
    public func finish() {
        guard isRunning else { return }
        isRunning = false
        let token = generation
        status = "Recording ended · the saved transcript is processed separately"
        let previous = finishing
        finishing = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.recognizer.finish()
            if self.generation == token { self.history.finish() }
        }
    }

    /// Immediate teardown (setting turned off, failure, termination).
    public func stop(status: String? = nil) {
        generation = UUID()
        recognizer.stop()
        isRunning = false
        if let status { self.status = status }
    }
}
