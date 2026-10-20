#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesUI

/// First launch: what Minutes does, the one-time setup recording needs, and
/// the person's acknowledgement that they will tell others when they record.
@available(macOS 15.0, iOS 18.0, *)
public struct WelcomeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .medium))
                        .frame(width: 64, height: 64).minutesControlGlass(in: Circle())
                    Text("Welcome to Minutes").font(.largeTitle.bold())
                    Text("Record a meeting and get a transcript, speakers and a summary, all made on this device.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                step(number: "1", title: "Install speech models", done: appState.recordingModelsReady) {
                    Text(appState.recordingModelsReady ? "Ready." : "A one-time download that lets Minutes tell speakers apart. After this, meetings are processed offline.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !appState.recordingModelsReady {
                        Button(appState.isSettingUpSpeechModels ? "Installing…" : "Install Models") { Task { await appState.setupSpeechModels() } }
                            .disabled(appState.isSettingUpSpeechModels)
                        if appState.isSettingUpSpeechModels { Text(appState.speechModelStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                step(number: "2", title: "Allow the microphone", done: permissions.micStatus == .granted) {
                    Text("Minutes listens only while you record.").foregroundStyle(.secondary)
                    if permissions.micStatus != .granted {
                        Button("Allow Microphone") { Task { _ = await permissions.requestMicrophoneAccess() } }
                    }
                }
                step(number: "3", title: "Let people know you're recording", done: appState.recordingConsentAcknowledged) {
                    Text("Many places require everyone's permission before a conversation is recorded. Minutes doesn't join calls or announce itself, so tell participants yourself, and only remember someone's voice if they agree.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    appState.recordingConsentAcknowledged = true
                    appState.welcomeCompleted = true
                } label: {
                    Text("I'll ask before recording").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain)
                Text("You can install models and allow access later from Settings.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(32).frame(maxWidth: 560)
        }
        .frame(minWidth: 420, minHeight: 560)
        .onAppear { permissions.checkAllPermissions(); appState.refreshSpeechReadiness() }
        .interactiveDismissDisabled()
    }

    private func step(number: String, title: String, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.yellow : Color.primary.opacity(0.08))
                if done { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black) }
                else { Text(number).font(.callout.weight(.semibold)) }
            }.frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(done ? "\(title), done" : title)
    }
}
#endif
