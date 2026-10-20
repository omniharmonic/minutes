#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import MinutesCore
import MinutesSpeech

/// Audio stays discoverable even when recognition cannot produce a transcript.
/// The waveform is the scrubber; marked moments sit on it as pins.
@available(macOS 15.0, iOS 18.0, *)
public struct SavedRecordingPlayer: View {
    public let path: String
    public let isEnabled: Bool
    public let onRegenerate: (() -> Void)?
    public let isProcessing: Bool
    public let bookmarks: [Bookmark]
    public let onMarkMoment: ((Double) -> Void)?
    @ObservedObject private var playback = AudioPlaybackService.shared
    @State private var fileDuration: Double = 0
    @State private var peaks: [Float] = []
    @State private var error: String?
    @State private var scrubbing: Double?
    public init(path: String, isEnabled: Bool = true, onRegenerate: (() -> Void)? = nil, isProcessing: Bool = false,
                bookmarks: [Bookmark] = [], onMarkMoment: ((Double) -> Void)? = nil) {
        self.path = path; self.isEnabled = isEnabled; self.onRegenerate = onRegenerate; self.isProcessing = isProcessing
        self.bookmarks = bookmarks; self.onMarkMoment = onMarkMoment
    }
    private var loaded: Bool { playback.currentAudioPath == path }
    private var playing: Bool { loaded && playback.isPlaying }
    private var position: Double { scrubbing ?? (loaded ? playback.currentTime : 0) }
    private var duration: Double { loaded && playback.duration > 0 ? playback.duration : fileDuration }
    #if os(iOS)
    private let control: CGFloat = 44
    #else
    private let control: CGFloat = 36
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { playButton; waveform.frame(minWidth: 320); clock; actions }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { playButton; clock; Spacer(minLength: 4); actions }
                    waveform
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !isEnabled { Text("Playback is available when recording finishes.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .minutesControlGlass(in: RoundedRectangle(cornerRadius: 22))
        .disabled(!isEnabled)
        .task(id: path + String(isEnabled)) { await loadSummary() }
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold)).frame(width: control + 8, height: control + 8)
                .contentTransition(.symbolEffect(.replace))
                .minutesControlGlass(in: Circle(), interactive: true)
        }.buttonStyle(.plain).accessibilityLabel(playing ? "Pause recording" : "Play saved recording")
    }

    private var clock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(SummaryCitations.timecode(position)).font(.callout.monospacedDigit().weight(.medium))
            Text(SummaryCitations.timecode(max(0, duration))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.fixedSize().accessibilityElement(children: .combine).accessibilityLabel("Position")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let onMarkMoment {
                Button { onMarkMoment(position) } label: {
                    Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold))
                        .frame(width: control, height: control).minutesControlGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).help("Mark this moment").accessibilityLabel("Mark moment at \(SummaryCitations.timecode(position))")
            }
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Group {
                        if isProcessing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.trianglehead.2.clockwise").font(.system(size: 14, weight: .semibold)) }
                    }
                    .frame(width: control, height: control).minutesControlGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).disabled(isProcessing)
                    .help("Regenerate transcript, speakers and summary from this recording")
                    .accessibilityLabel(isProcessing ? "Processing recording" : "Regenerate from recording")
            }
        }
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let bars = peaks.isEmpty ? [Float](repeating: 0.08, count: 120) : peaks
                    let step = size.width / CGFloat(bars.count)
                    let barWidth = max(1.5, step * 0.55)
                    let mid = size.height / 2 + 4
                    for (index, peak) in bars.enumerated() {
                        let x = CGFloat(index) * step + (step - barWidth) / 2
                        let height = max(2, CGFloat(peak) * (size.height - 14))
                        let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
                        let played = (x + barWidth / 2) / size.width <= progress
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                     with: .color(played ? Color.primary.opacity(0.9) : Color.primary.opacity(0.22)))
                    }
                }
                ForEach(bookmarks) { bookmark in
                    if duration > 0 {
                        Button { seek(to: bookmark.timestamp, play: true) } label: {
                            Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(bookmark.label) · \(SummaryCitations.timecode(bookmark.timestamp))")
                        .accessibilityLabel("Play \(bookmark.label) at \(SummaryCitations.timecode(bookmark.timestamp))")
                        .offset(x: width * min(1, bookmark.timestamp / duration) - 11, y: -9)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in scrubbing = duration * min(1, max(0, value.location.x / width)) }
                .onEnded { value in
                    let target = duration * min(1, max(0, value.location.x / width))
                    scrubbing = nil
                    seek(to: target, play: playing)
                })
            .accessibilityElement()
            .accessibilityLabel("Recording timeline")
            .accessibilityValue("\(SummaryCitations.timecode(position)) of \(SummaryCitations.timecode(duration))")
            .accessibilityAdjustableAction { direction in
                seek(to: max(0, min(duration, position + (direction == .increment ? 15 : -15))), play: playing)
            }
        }
        .frame(height: 52)
    }

    private func togglePlayback() {
        guard isEnabled else { return }
        do {
            if playing { playback.pause(); return }
            if !loaded { try playback.loadAudio(path: path) }
            let start = playback.currentTime >= playback.duration ? 0 : playback.currentTime
            guard playback.play(from: start) else { throw CocoaError(.fileReadUnknown) }
        } catch { self.error = "The saved audio could not play: \(error.localizedDescription)" }
    }

    private func seek(to seconds: Double, play: Bool) {
        guard isEnabled else { return }
        do {
            if !loaded { try playback.loadAudio(path: path) }
            if play { playback.play(from: seconds) } else { playback.seek(to: seconds) }
        } catch { self.error = "The saved audio could not play: \(error.localizedDescription)" }
    }

    private func loadSummary() async {
        guard isEnabled else { return }
        let sourcePath = path
        do {
            let (length, envelope) = try await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: sourcePath)
                let audio = try AVAudioFile(forReading: url)
                let seconds = audio.fileFormat.sampleRate > 0 ? Double(audio.length) / audio.fileFormat.sampleRate : 0
                return (seconds, (try? AudioWaveformSummary.peaks(url: url, bins: 160)) ?? [])
            }.value
            fileDuration = length; peaks = envelope
        } catch { self.error = "Saved audio could not be opened: \(error.localizedDescription)" }
    }
}
#endif
