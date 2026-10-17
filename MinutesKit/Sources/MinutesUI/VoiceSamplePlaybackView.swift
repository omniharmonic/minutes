#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeech

/// Shared sample controls for meeting review and the People voice picker.
@available(macOS 15.0, iOS 18.0, *)
public struct VoiceSamplePlaybackView: View {
    let meeting: Meeting
    let cluster: SpeakerCluster
    let utterances: [Utterance]
    let playbackAllowed: Bool
    @ObservedObject private var playback = AudioPlaybackService.shared
    @State private var loadedPath: String?
    @State private var playbackError: String?
    @State private var ownsPlayback = false

    public init(meeting: Meeting, cluster: SpeakerCluster, utterances: [Utterance], playbackAllowed: Bool = true) {
        self.meeting = meeting
        self.cluster = cluster
        self.utterances = utterances
        self.playbackAllowed = playbackAllowed
    }

    private var sample: SpeakerAudioSample? {
        SpeakerAudioSample(utterances: utterances, clusterID: cluster.id)
    }

    private var unavailableReason: String? {
        if !playbackAllowed { return "Finish recording before listening to a sample." }
        if meeting.platform == "transcript_import" || meeting.audioPath == nil { return "This transcript has no recorded audio." }
        if let path = meeting.audioPath, !FileManager.default.fileExists(atPath: path) { return "The recording is unavailable on this device." }
        if sample == nil { return "No timed speech sample is available for this speaker." }
        return nil
    }

    private var isCurrentSample: Bool {
        guard let sample, let loadedPath else { return false }
        return playback.currentAudioPath == loadedPath && playback.currentTime >= sample.start && playback.currentTime <= sample.end + 0.05
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Label(isCurrentSample && playback.isPlaying ? "Pause sample" : "Listen to sample",
                          systemImage: isCurrentSample && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain).disabled(unavailableReason != nil)
                if let sample {
                    Text("\(clock(sample.start))–\(clock(sample.end))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let reason = unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if let sample, loadedPath != nil {
                let elapsed = isCurrentSample ? playback.currentTime - sample.start : 0
                ProgressView(value: max(0, min(elapsed, sample.end - sample.start)), total: sample.end - sample.start)
                    .accessibilityLabel("Sample playback progress")
                Text(isCurrentSample ? "\(clock(elapsed)) of \(clock(sample.end - sample.start))" : "\(clock(sample.end - sample.start)) sample")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let playbackError {
                Label(playbackError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: playbackAllowed) { _, allowed in
            if !allowed && ownsPlayback { playback.pause() }
        }
        .onDisappear { if ownsPlayback && playback.currentAudioPath == loadedPath { playback.pause() } }
    }

    private func togglePlayback() {
        guard unavailableReason == nil, let sample else { return }
        if isCurrentSample && playback.isPlaying { playback.pause(); return }
        do {
            let path = try SpeakerAudioSample.audioPath(meeting: meeting, cluster: cluster)
            let resumeTime = isCurrentSample && playback.currentTime < sample.end ? playback.currentTime : sample.start
            if playback.currentAudioPath != path { try playback.loadAudio(path: path) }
            loadedPath = path
            ownsPlayback = true
            playbackError = nil
            guard resumeTime < playback.duration else {
                playbackError = "This sample is outside the available recording. Try another speaker or recording."
                return
            }
            if !playback.play(from: resumeTime, to: min(sample.end, playback.duration)) {
                playbackError = "Audio playback could not start. Check the audio output and try again."
            }
        } catch { playbackError = error.localizedDescription }
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
#endif
