#if canImport(SwiftUI)
import SwiftUI
import MinutesSpeakerID

/// How sure Minutes must be before it names speakers without asking.
@available(macOS 15.0, iOS 18.0, *)
public struct SpeakerNamingSettings: View {
    @ObservedObject var appState: AppState
    public init(appState: AppState) { self.appState = appState }

    private var policy: Binding<SpeakerAutoLabelPolicy> { $appState.speakerAutoLabelPolicy }

    public var body: some View {
        Section {
            Toggle(isOn: policy.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name speakers automatically")
                    Text("Uses voices you chose to remember, before the summary is written, so the summary says who said what.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if appState.speakerAutoLabelPolicy.enabled {
                Picker("Confidence", selection: Binding(
                    get: { appState.speakerAutoLabelPolicy.preset },
                    set: { preset in
                        guard preset != .custom else { appState.speakerAutoLabelPolicy.preset = .custom; return }
                        var next = SpeakerAutoLabelPolicy.preset(preset)
                        next.nameLastInvitee = appState.speakerAutoLabelPolicy.nameLastInvitee
                        appState.speakerAutoLabelPolicy = next
                    })) {
                    Text("Cautious").tag(SpeakerAutoLabelPolicy.Preset.cautious)
                    Text("Balanced").tag(SpeakerAutoLabelPolicy.Preset.balanced)
                    Text("Eager").tag(SpeakerAutoLabelPolicy.Preset.eager)
                    Text("Custom").tag(SpeakerAutoLabelPolicy.Preset.custom)
                }
                Text(description).font(.caption).foregroundStyle(.secondary)
                if appState.speakerAutoLabelPolicy.preset == .custom {
                    LabeledContent("Voice match") {
                        Slider(value: customBinding(\.similarity), in: 0.55...0.95, step: 0.01)
                        Text(appState.speakerAutoLabelPolicy.similarity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 44)
                    }
                    LabeledContent("Lead over next voice") {
                        Slider(value: customBinding(\.margin), in: 0.05...0.30, step: 0.01)
                        Text(appState.speakerAutoLabelPolicy.margin, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 44)
                    }
                    LabeledContent("Minimum speech") {
                        Stepper("\(Int(appState.speakerAutoLabelPolicy.minimumSpeechSeconds)) s", value: customBinding(\.minimumSpeechSeconds), in: 2...30)
                    }
                }
                Toggle(isOn: policy.nameLastInvitee) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Name the last remaining invitee")
                        Text("When every calendar invitee but one is recognized and one long-speaking voice is left, give it that name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Speakers")
        } footer: {
            Text("Automatic names are marked so you can review them, and correcting one updates the summary and your vault note. Remembered voices never leave this device.")
        }
    }

    private var description: String {
        switch appState.speakerAutoLabelPolicy.preset {
        case .cautious: "Names only near-certain matches. Expect more “Speaker 2” labels."
        case .balanced: "Recommended. Names clear matches and leaves close calls unnamed."
        case .eager: "Names more speakers; occasionally a similar voice may be mislabeled."
        case .custom: "Set your own thresholds. Higher values name fewer speakers but are wrong less often."
        }
    }

    private func customBinding(_ keyPath: WritableKeyPath<SpeakerAutoLabelPolicy, Double>) -> Binding<Double> {
        Binding(get: { appState.speakerAutoLabelPolicy[keyPath: keyPath] },
                set: { value in
                    var next = appState.speakerAutoLabelPolicy
                    next[keyPath: keyPath] = value
                    next.preset = .custom
                    appState.speakerAutoLabelPolicy = next
                })
    }
}
#endif
