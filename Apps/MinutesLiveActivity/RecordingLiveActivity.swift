import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import MinutesActivity

@main
struct MinutesLiveActivityBundle: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecordingView(state: context.state)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(state.phase == .recording ? "Recording" : "Saving") } icon: { RecordingDot(phase: state.phase) }
                        .font(.caption.weight(.semibold)).foregroundStyle(state.phase == .recording ? .red : .secondary)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: state).font(.body.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 76, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.caption.weight(.medium)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        WaveformBars(levels: state.normalizedLevels, color: .red).frame(height: 22)
                        if let caption = state.caption {
                            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        RecordingButtons(phase: state.phase)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    RecordingDot(phase: state.phase)
                    WaveformBars(levels: Array(state.normalizedLevels.suffix(5)), color: .red).frame(width: 18, height: 12)
                }
            } compactTrailing: {
                ElapsedText(state: state).font(.caption2.monospacedDigit()).frame(maxWidth: 44)
            } minimal: {
                RecordingDot(phase: state.phase)
            }
            .keylineTint(.red)
        }
    }
}

private struct LockScreenRecordingView: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingDot(phase: state.phase)
                Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                ElapsedText(state: state).font(.title3.monospacedDigit().weight(.semibold))
            }
            WaveformBars(levels: state.normalizedLevels, color: .red).frame(height: 26)
            if let caption = state.caption {
                Text(caption).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.phase == .recording {
                RecordingButtons(phase: state.phase)
            } else {
                Text("Saving on this iPhone…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Duration.seconds(state.frozenElapsed ?? 0), format: .time(pattern: (state.frozenElapsed ?? 0) >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
    }
}

private struct RecordingDot: View {
    let phase: RecordingActivityAttributes.ContentState.Phase
    var body: some View {
        Circle().fill(phase == .recording ? Color.red : Color.secondary).frame(width: 8, height: 8)
            .accessibilityLabel(phase == .recording ? "Recording" : "Saving")
    }
}

private struct WaveformBars: View {
    let levels: [Double]
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            let count = max(1, levels.count)
            let spacing: CGFloat = count > 8 ? 2 : 1
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(color.opacity(0.35 + 0.65 * level))
                        .frame(width: width, height: max(2, proxy.size.height * level))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct RecordingButtons: View {
    let phase: RecordingActivityAttributes.ContentState.Phase
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: MarkMomentIntent()) {
                Label("Moment", systemImage: "bookmark.fill").frame(maxWidth: .infinity)
            }
            .tint(.orange)
            Button(intent: StopRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .font(.footnote.weight(.semibold))
        .disabled(phase != .recording)
    }
}
