#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeech

/// Inline recording controls. Meter samples come exclusively from the recorder.
@available(macOS 15.0, iOS 18.0, *)
public struct RecordingWorkspaceView: View {
    @State private var inputDevice: CaptureInputDevice?
    @State private var choosingSource = false
    public let isRecording: Bool
    public let isBusy: Bool
    public let busyMessage: String
    public let canStart: Bool
    public let modelsReady: Bool
    public let isInstalling: Bool
    public let readinessMessage: String
    public let statusMessage: String
    public let routeNotice: String?
    public let meter: RecordingMeterModel
    @Binding public var source: String
    public let sources: [String]
    public let includesMicrophone: Bool
    public let onInstall: () -> Void
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let moments: [Bookmark]
    public let onMarkMoment: (() -> Void)?
    public let onRenameMoment: ((Bookmark, String) -> Void)?
    public let onRemoveMoment: ((Bookmark) -> Void)?
    @State private var markPulse = 0
    @State private var editingMoment: Bookmark?
    @State private var momentName = ""

    public init(isRecording: Bool, isBusy: Bool, busyMessage: String = "Checking Recording Permissions…", canStart: Bool, modelsReady: Bool, isInstalling: Bool,
                readinessMessage: String, statusMessage: String, routeNotice: String? = nil, meter: RecordingMeterModel,
                source: Binding<String>, sources: [String], includesMicrophone: Bool = true, onInstall: @escaping () -> Void,
                onStart: @escaping () -> Void, onStop: @escaping () -> Void, moments: [Bookmark] = [],
                onMarkMoment: (() -> Void)? = nil, onRenameMoment: ((Bookmark, String) -> Void)? = nil,
                onRemoveMoment: ((Bookmark) -> Void)? = nil) {
        self.moments = moments; self.onMarkMoment = onMarkMoment; self.onRenameMoment = onRenameMoment; self.onRemoveMoment = onRemoveMoment
        self.isRecording = isRecording; self.isBusy = isBusy; self.busyMessage = busyMessage; self.canStart = canStart
        self.modelsReady = modelsReady; self.isInstalling = isInstalling
        self.readinessMessage = readinessMessage; self.statusMessage = statusMessage; self.routeNotice = routeNotice
        self.meter = meter; self._source = source; self.sources = sources
        self.includesMicrophone = includesMicrophone
        self.onInstall = onInstall; self.onStart = onStart; self.onStop = onStop
    }
    public var body: some View {
        Group {
            if isRecording { activeRecordingContent }
            else { preRecordingContent }
        }
        .onAppear { inputDevice = CaptureInputDevices.current() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            inputDevice = CaptureInputDevices.current()
        }
    }
    private var activeRecordingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            RecordingLiveReadout(meter: meter, source: source, includesMicrophone: includesMicrophone)
            if includesMicrophone, let inputDevice { Label(inputDevice.name, systemImage: "mic").font(.caption).foregroundStyle(.secondary) }
            if let routeNotice {
                Label(routeNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if let onMarkMoment {
                    Button {
                        onMarkMoment(); markPulse += 1
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bookmark.fill").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(width: 34, height: 34).background(Color.yellow, in: Circle())
                                .symbolEffect(.bounce, value: markPulse)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Mark this moment").font(.callout.weight(.semibold))
                                #if os(macOS)
                                Text("⌘B").font(.caption2).foregroundStyle(.secondary)
                                #endif
                            }
                        }
                        .padding(.leading, 8).padding(.trailing, 18).frame(minHeight: 50)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(isBusy || meter.duration <= 0)
                    .sensoryFeedback(.impact(weight: .medium), trigger: markPulse)
                    .accessibilityLabel("Mark this moment").accessibilityIdentifier("recording.mark")
                }
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 22).frame(minHeight: 50)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).disabled(isBusy)
                    .accessibilityLabel("Stop Recording").accessibilityIdentifier("recording.stop")
            }
            if !moments.isEmpty { momentStrip }
            Text(onMarkMoment == nil ? "Saved on this device. Your transcript and summary follow when you stop."
                 : "Mark what matters as it happens. Moments sit on the timeline and beside the transcript when you stop.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).minutesControlGlass(in: RoundedRectangle(cornerRadius: 20))
        .alert("Name this moment", isPresented: Binding(get: { editingMoment != nil }, set: { if !$0 { editingMoment = nil } })) {
            TextField("What happened?", text: $momentName)
            Button("Save") { if let moment = editingMoment { onRenameMoment?(moment, momentName) }; editingMoment = nil }
            if let moment = editingMoment, let onRemoveMoment {
                Button("Remove", role: .destructive) { onRemoveMoment(moment); editingMoment = nil }
            }
            Button("Cancel", role: .cancel) { editingMoment = nil }
        }
    }

    /// Marked moments as chips, newest last; tap one to name it.
    private var momentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(moments.sorted { $0.timestamp < $1.timestamp }) { moment in
                    Button { momentName = moment.label == "Key moment" ? "" : moment.label; editingMoment = moment } label: {
                        HStack(spacing: 6) {
                            Text(SummaryCitations.timecode(moment.timestamp)).font(.caption.monospacedDigit().weight(.semibold))
                            Text(moment.label).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .background(Color.yellow.opacity(0.2), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(moment.label) at \(SummaryCitations.timecode(moment.timestamp))")
                    .accessibilityHint("Name or remove this moment")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: moments.map(\.id))
        }
    }
    private var preRecordingContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 76, height: 76).minutesControlGlass(in: Circle())
                    .accessibilityHidden(true)
                Text(isBusy ? busyMessage : "New Recording")
                    .font(.system(size: 30, weight: .semibold)).multilineTextAlignment(.center)
            }
            if sources.count > 1 {
                Button { choosingSource = true } label: { sourcePillLabel }
                    .buttonStyle(.plain).disabled(isBusy || isInstalling)
                    .accessibilityLabel("Audio source").accessibilityValue(source)
                    .popover(isPresented: $choosingSource) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sources, id: \.self) { option in
                                Button {
                                    source = option
                                    choosingSource = false
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: source == option ? "checkmark" : "circle")
                                            .frame(width: 20)
                                        Text(option)
                                        Spacer(minLength: 12)
                                    }.padding(.horizontal, 14).padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(option)
                                    .accessibilityValue(source == option ? "Selected" : "")
                            }
                        }.padding(8).frame(minWidth: 280)
                            .presentationCompactAdaptation(.popover)
                    }
            } else { sourcePillLabel }
            if includesMicrophone && source != "Microphone" {
                Text("Use headphones to keep call audio out of your microphone.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if includesMicrophone, let inputDevice {
                VStack(spacing: 6) {
                    Label(inputDevice.name, systemImage: "mic").font(.callout)
                    if inputDevice.isBluetooth {
                        Text("Bluetooth microphones can reduce speech clarity. For clearer recordings, choose the built-in or a wired microphone in Sound settings.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            if !includesMicrophone {
                Label("Microphone is off", systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if modelsReady {
                Label("Local models ready", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    Text("Install local speech models").font(.headline)
                    Text(readinessMessage).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    Button(action: onInstall) {
                        Label(isInstalling ? "Installing Models…" : "Install Models", systemImage: "arrow.down.to.line")
                            .font(.callout.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 11)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain).disabled(isInstalling || isBusy)
                }
            }
            if isBusy || isInstalling { ProgressView().controlSize(.small) }
            Button(action: onStart) {
                Label("Record", systemImage: "record.circle")
                    .labelStyle(RecordingActionLabelStyle())
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .minutesControlGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain).disabled(!canStart).opacity(canStart ? 1 : 0.5)
            .accessibilityLabel("Start Recording")
            if statusMessage != "Ready" && !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled).lineLimit(4)
            }
            Text("Audio stays on this device. Transcription begins when you stop.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 560).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
    private var sourcePillLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: sources.count > 1 && source != (sources.first ?? "") ? "speaker.wave.2" : "mic")
            Text(source).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            if sources.count > 1 { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .minutesControlGlass(in: Capsule(), interactive: sources.count > 1)
    }
}

/// Only this small readout observes the 20 Hz stream; parent workspace, notes,
/// navigation and controls keep their normal app-state update frequency.
@available(macOS 15.0, iOS 18.0, *)
private struct RecordingLiveReadout: View {
    @ObservedObject var meter: RecordingMeterModel
    let source: String
    let includesMicrophone: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: includesMicrophone ? "mic.fill" : "speaker.wave.2.fill").font(.system(size: 17)).frame(width: 36, height: 36)
                    .minutesControlGlass(in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(meter.duration > 0 ? "Recording" : "Starting Recording…").font(.headline)
                    Label(source, systemImage: meter.level == nil ? "speaker.wave.2" : "mic")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Duration.seconds(meter.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 28, weight: .light, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("Recording duration")
            }
            if let level = meter.level {
                Canvas { context, size in
                    let samples = meter.snapshot.history
                    let spacing: CGFloat = 2
                    let width = max(1, min(4, (size.width - CGFloat(samples.count - 1) * spacing) / CGFloat(samples.count)))
                    let total = CGFloat(samples.count) * width + CGFloat(samples.count - 1) * spacing
                    let origin = (size.width - total) / 2
                    var bars = Path()
                    for (index, sample) in samples.enumerated() {
                        let height = max(2, CGFloat(sample) * 44)
                        let rect = CGRect(x: origin + CGFloat(index) * (width + spacing), y: (size.height - height) / 2,
                            width: width, height: height)
                        bars.addRoundedRect(in: rect, cornerSize: CGSize(width: width / 2, height: width / 2))
                    }
                    context.fill(bars, with: .color(.primary.opacity(0.85)))
                }
                .frame(height: 48)
                .accessibilityElement(children: .ignore).accessibilityLabel("Recent microphone levels")
                .accessibilityValue("\(Int(level * 100)) percent")
            } else {
                Label(includesMicrophone ? "Call audio and microphone are being saved" : "Mac audio is being saved · microphone off", systemImage: "waveform")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecordingActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
            configuration.title.font(.headline).foregroundStyle(.primary)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
public struct RecordingLaunchButton: View {
    public enum Style: Sendable { case pill, circle }
    public let isRecording: Bool
    public let duration: Double
    public let style: Style
    public let action: () -> Void
    public init(isRecording: Bool, duration: Double, style: Style = .pill, action: @escaping () -> Void) {
        self.isRecording = isRecording; self.duration = duration; self.style = style; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            switch style {
            case .pill: pill
            case .circle: circle
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Show Recording" : "Record a Meeting")
        .accessibilityValue(isRecording ? Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)) : "")
        .help(isRecording ? "Show the active recording" : "Record a meeting")
        .frame(maxWidth: .infinity)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(isRecording ? Color.red : Color.primary)
            Text(isRecording ? "Recording" : "Record")
                .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            if isRecording {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 44)
        .minutesControlGlass(in: Capsule(), interactive: true)
        .contentShape(Capsule())
    }

    /// Voice Memos proportions: a red core that nearly fills a thin glass ring.
    private var circle: some View {
        ZStack {
            if isRecording {
                RoundedRectangle(cornerRadius: 7).fill(Color.red).frame(width: 24, height: 24)
            } else {
                Circle().fill(Color.red).frame(width: 48, height: 48)
            }
        }
        .frame(width: 60, height: 60)
        .minutesClearGlass(in: Circle())
        .contentShape(Circle())
        .overlay(alignment: .top) {
            if isRecording {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .minutesClearGlass(in: Capsule())
                    .fixedSize().offset(y: -30)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isRecording)
    }
}
#endif
