import Foundation
import Speech
import AVFoundation

/// Local-only preview. Independent from final ASR, permissions and recording ownership.
@MainActor public final class LiveCaptionRecognizer {
    public typealias Update = @MainActor (String, String, String, Bool, Int) -> Void
    public typealias AudioWindow = @MainActor (String, [Float], Double) -> Void
    public struct Diagnostics: Sendable {
        public var sessionsStarted = 0
        public var scheduledRotations = 0
        public var recognitionRetries = 0
        public var droppedBatches = 0
    }
    public private(set) var diagnostics = Diagnostics()
    private var audioWindow: AudioWindow?
    private var retiring: [String: Session] = [:]
    private struct Session {
        let id: String
        let recognizer: SFSpeechRecognizer
        let rate: Double
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
        var frames: Int = 0
        var lastSignalFrame: Int = 0
        var text = ""
        var samples: [Float] = []
        var source = ""
        var order = 0
    }
    private var sessions: [String: Session] = [:]
    private var timer: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var epoch = UUID()
    private var retryAfter: [String: Date] = [:]
    private var waitingSources: Set<String> = []
    private var failures: [String: Int] = [:]
    private var update: Update?
    private var notice: (@MainActor (String) -> Void)?
    public init() {}
    public func start(audioWindow: AudioWindow? = nil, update: @escaping Update, notice: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw ASRError.authorizationDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw ASRError.recognizerUnavailable("Local English live captions are unavailable. Your recording can continue.")
        }
        diagnostics = Diagnostics(); waitingSources.removeAll(); retryAfter.removeAll(); failures.removeAll()
        self.audioWindow = audioWindow
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
            diagnostics.droppedBatches += 1
            resetSessions()
            notice?("Preview skipped some audio to catch up. The saved recording is unaffected.")
        }
        for chunk in batch.chunks {
            guard chunk.rate.isFinite, chunk.rate > 0, failures[chunk.source, default: 0] < 5,
                  Date() >= retryAfter[chunk.source, default: .distantPast] else { continue }
            if let current = sessions[chunk.source], current.rate != chunk.rate {
                retire(current, source: chunk.source)
            }
            var offset = 0
            let maximumFrames = Int(chunk.rate * (audioWindow == nil ? 45 : 10))
            while offset < chunk.samples.count {
                if sessions[chunk.source] == nil {
                    guard CaptionSilenceGate.containsSignal(Array(chunk.samples[offset...])) else { break }
                    createSession(source: chunk.source, rate: chunk.rate)
                }
                guard var session = sessions[chunk.source] else { break }
                let count = min(chunk.samples.count - offset, maximumFrames - session.frames)
                guard count > 0, let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let data = buffer.floatChannelData else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { data[0][i] = chunk.samples[offset + i] }
                if audioWindow != nil { session.samples.append(contentsOf: chunk.samples[offset..<(offset + count)]) }
                if CaptionSilenceGate.containsSignal(Array(chunk.samples[offset..<(offset + count)])) {
                    session.lastSignalFrame = session.frames + count
                }
                session.request.append(buffer); session.frames += count; sessions[chunk.source] = session
                offset += count
                if session.frames == maximumFrames { diagnostics.scheduledRotations += 1; retire(session, source: chunk.source) }
            }
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
            let failed = error != nil && !final
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation,
                      self.sessions[source]?.id == id || self.retiring[id] != nil else { return }
                let isRetiring = self.retiring[id] != nil
                let current = self.retiring[id] ?? self.sessions[source]
                let quietEnd = current.map { CaptionSilenceGate.isQuietTail(frames: $0.frames, lastSignal: $0.lastSignalFrame, rate: $0.rate) } ?? false
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let previous = isRetiring ? self.retiring[id]?.text : self.sessions[source]?.text
                    let order = (isRetiring ? self.retiring[id]?.order : self.sessions[source]?.order) ?? 0
                    if isRetiring { self.retiring[id]?.text = text }
                    else { self.sessions[source]?.text = text }
                    self.update?(id, text, source, final, order)
                    if !isRetiring && previous != text {
                        let wasWaiting = self.waitingSources.remove(source) != nil
                        if self.failures[source, default: 0] > 0 || wasWaiting { self.notice?("Listening locally · preview may change") }
                        self.failures[source] = 0
                    }
                }
                if final || failed {
                    if isRetiring { self.retiring.removeValue(forKey: id)?.task.cancel() }
                    else if let completed = self.sessions.removeValue(forKey: source) {
                        self.audioWindow?(id, completed.samples, completed.rate)
                        completed.task.cancel()
                    }
                    if failed && !isRetiring && quietEnd {
                        self.failures[source] = 0
                        self.waitingSources.insert(source)
                        self.notice?("Waiting for speech · your recording continues")
                    } else if failed && !isRetiring {
                        self.diagnostics.recognitionRetries += 1
                        self.failures[source, default: 0] += 1
                        self.retryAfter[source] = Date().addingTimeInterval(self.failures[source, default: 0] > 1 ? 2 : 0)
                        self.notice?(self.failures[source, default: 0] >= 5
                            ? "Live preview paused after repeated recognition errors. Close and reopen captions to retry; your recording continues."
                            : "Reconnecting live recognition · your recording is safe")
                    }
                }
            }
        }
        diagnostics.sessionsStarted += 1
        sessions[source] = Session(id: id, recognizer: recognizer, rate: rate, request: request, task: task, source: source, order: diagnostics.sessionsStarted - 1)
    }
    private func retire(_ session: Session, source: String) {
        sessions.removeValue(forKey: source)
        // Keep the task alive briefly so endAudio can deliver the last words.
        if retiring.count >= 4, let oldest = retiring.values.first {
            update?(oldest.id, oldest.text, oldest.source, true, oldest.order)
            retiring.removeValue(forKey: oldest.id)?.task.cancel()
        }
        retiring[session.id] = session
        audioWindow?(session.id, session.samples, session.rate)
        session.request.endAudio()
        let token = epoch
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.epoch == token,
                  let finished = self.retiring.removeValue(forKey: session.id) else { return }
            self.update?(finished.id, finished.text, source, true, finished.order)
            finished.task.cancel()
        }
    }
    public func finish() async {
        timer?.cancel(); timer = nil
        consume()
        CaptionAudioFeed.shared.setEnabled(false)
        let token = epoch
        for (source, session) in sessions { retire(session, source: source) }
        try? await Task.sleep(for: .seconds(2))
        guard epoch == token else { return }
        for session in retiring.values { update?(session.id, session.text, session.source, true, session.order) }
        stop()
    }
    private func resetSessions() {
        epoch = UUID()
        for session in sessions.values { session.request.endAudio(); session.task.cancel() }
        for session in retiring.values { session.task.cancel() }
        retiring.removeAll(); sessions.removeAll()
    }
    public func stop() {
        timer?.cancel(); timer = nil
        CaptionAudioFeed.shared.setEnabled(false)
        resetSessions(); audioWindow = nil; recognizer = nil; update = nil; notice = nil
    }
}
