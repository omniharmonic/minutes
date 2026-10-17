import Foundation
import Speech
import AVFoundation

/// Local-only preview. Independent from final ASR, permissions and recording ownership.
@MainActor public final class LiveCaptionRecognizer {
    public typealias Update = @MainActor (String, String, String, Bool) -> Void
    private struct Session {
        let id: String
        let recognizer: SFSpeechRecognizer
        let rate: Double
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
        var frames: Int = 0
        var text = ""
    }
    private var sessions: [String: Session] = [:]
    private var timer: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var epoch = UUID()
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var update: Update?
    private var notice: (@MainActor (String) -> Void)?
    public init() {}
    public func start(update: @escaping Update, notice: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw ASRError.authorizationDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw ASRError.recognizerUnavailable("Local English live captions are unavailable. Your recording can continue.")
        }
        retryAfter.removeAll(); failures.removeAll()
        self.recognizer = recognizer; self.update = update; self.notice = notice
        CaptionAudioFeed.shared.setEnabled(true)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.consume()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func consume() {
        let batch = CaptionAudioFeed.shared.drain()
        if batch.dropped {
            resetSessions()
            notice?("Preview skipped some audio to catch up. The saved recording is unaffected.")
        }
        for chunk in batch.chunks {
            guard chunk.rate.isFinite, chunk.rate > 0, failures[chunk.source, default: 0] < 5,
                  Date() >= retryAfter[chunk.source, default: .distantPast] else { continue }
            if let current = sessions[chunk.source], current.rate != chunk.rate || Double(current.frames) / current.rate >= 45 {
                update?(current.id, current.text, chunk.source, true)
                current.request.endAudio(); current.task.cancel(); sessions.removeValue(forKey: chunk.source)
            }
            if sessions[chunk.source] == nil { createSession(source: chunk.source, rate: chunk.rate) }
            guard var session = sessions[chunk.source], let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)), let data = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            for i in chunk.samples.indices { data[0][i] = chunk.samples[i] }
            session.request.append(buffer); session.frames += chunk.samples.count; sessions[chunk.source] = session
        }
    }
    private func createSession(source: String, rate: Double) {
        guard self.recognizer != nil, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        let id = UUID().uuidString, generation = epoch
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation, self.sessions[source]?.id == id else { return }
                if let text {
                    self.sessions[source]?.text = text
                    self.update?(id, text, source, final)
                    self.failures[source] = 0
                }
                if final || failed {
                    self.sessions.removeValue(forKey: source)?.task.cancel()
                    if failed {
                        self.failures[source, default: 0] += 1
                        self.retryAfter[source] = Date().addingTimeInterval(2)
                        self.notice?(self.failures[source, default: 0] >= 5
                            ? "Live preview paused after repeated recognition errors. Close and reopen captions to retry; your recording continues."
                            : "Live preview is restarting. Your recording continues; final transcription runs after Stop.")
                    }
                }
            }
        }
        sessions[source] = Session(id: id, recognizer: recognizer, rate: rate, request: request, task: task)
    }
    private func resetSessions() {
        epoch = UUID()
        for session in sessions.values { session.request.endAudio(); session.task.cancel() }
        sessions.removeAll()
    }
    public func stop() {
        timer?.cancel(); timer = nil
        CaptionAudioFeed.shared.setEnabled(false)
        resetSessions(); recognizer = nil; update = nil; notice = nil
    }
}
