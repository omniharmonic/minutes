#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import MinutesSpeech

/// Audio stays discoverable even when recognition cannot produce a transcript.
@available(macOS 15.0, iOS 18.0, *)
public struct SavedRecordingPlayer: View {
    public let path: String
    public let isEnabled: Bool
    public let onRegenerate: (() -> Void)?
    public let isProcessing: Bool
    @ObservedObject private var playback = AudioPlaybackService.shared
    @State private var fileDuration: Double = 0
    @State private var error: String?
    public init(path: String, isEnabled: Bool = true, onRegenerate: (() -> Void)? = nil, isProcessing: Bool = false) {
        self.path = path; self.isEnabled = isEnabled; self.onRegenerate = onRegenerate; self.isProcessing = isProcessing
    }
    private var loaded: Bool { playback.currentAudioPath == path }
    private var playing: Bool { loaded && playback.isPlaying }
    private var position: Double { loaded ? playback.currentTime : 0 }
    private var duration: Double { loaded ? playback.duration : fileDuration }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    guard isEnabled else { return }
                    do {
                        if playing { playback.pause(); return }
                        if !loaded { try playback.loadAudio(path: path) }
                        let start = playback.currentTime >= playback.duration ? 0 : playback.currentTime
                        guard playback.play(from: start) else { throw CocoaError(.fileReadUnknown) }
                    } catch { self.error = "The saved audio could not play: \(error.localizedDescription)" }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                        .minutesControlGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).accessibilityLabel(playing ? "Pause recording" : "Play saved recording")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved recording").font(.subheadline.weight(.medium))
                    Text(isEnabled ? "Listen to the original audio." : "Available when recording finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Duration.seconds(max(0, duration)).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Label(isProcessing ? "Processing recording…" : "Regenerate from Recording", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain).disabled(isProcessing)
                    .help("Transcribe saved audio again, identify speakers and update the automatic summary")
            }
            if loaded && duration > 0 {
                Slider(value: Binding(get: { min(duration, max(0, position)) }, set: { playback.seek(to: $0) }), in: 0...duration)
                    .accessibilityLabel("Recording playback position")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(14).minutesControlGlass(in: RoundedRectangle(cornerRadius: 18))
        .disabled(!isEnabled)
        .task(id: path + String(isEnabled)) {
            guard isEnabled else { return }
            do {
                let sourcePath = path
                fileDuration = try await Task.detached(priority: .utility) {
                    let audio = try AVAudioFile(forReading: URL(fileURLWithPath: sourcePath))
                    return audio.fileFormat.sampleRate > 0 ? Double(audio.length) / audio.fileFormat.sampleRate : 0
                }.value
            } catch { self.error = "Saved audio could not be opened: \(error.localizedDescription)" }
        }
    }
}
#endif
