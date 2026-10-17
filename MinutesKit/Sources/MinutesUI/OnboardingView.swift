#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

@available(macOS 15.0, iOS 18.0, *)
public struct OnboardingView: View {
    @ObservedObject public var permissionManager: PermissionManager
    public let onComplete: () -> Void
    public init(permissionManager: PermissionManager = .shared, onComplete: @escaping () -> Void) {
        self.permissionManager = permissionManager; self.onComplete = onComplete
    }
    public var body: some View {
        Form {
            Section {
                Text("Choose what Minutes can access").font(.title2.bold())
                Text("Recording starts only when you choose Record. You can import saved audio without microphone or calendar access.").foregroundStyle(.secondary)
            }
            Section {
                permissionRow("Microphone", icon: "mic", description: "Record your voice or an in-person conversation.", status: permissionManager.micStatus) {
                    Task { _ = await permissionManager.requestMicrophoneAccess() }
                }
                #if os(macOS)
                permissionRow("Call audio", icon: "waveform", description: "Capture the other side of a Mac call. macOS requires Screen & System Audio Recording permission; Minutes saves audio only, with no screen images.", status: permissionManager.systemAudioStatus) {
                    Task { _ = await permissionManager.requestSystemAudioAccess() }
                }
                #endif
                permissionRow("Apple Calendar", icon: "calendar", description: "Read upcoming meetings and invitees from your system calendars. Direct Google sign-in is available separately in Settings.", status: permissionManager.calendarStatus) {
                    Task { _ = await permissionManager.requestCalendarAccess() }
                }
                Button("Check permissions again") { permissionManager.checkAllPermissions() }
            } header: { Text("Permissions") }
            Section {
                Label("Audio and remembered voices stay on this device", systemImage: "internaldrive")
                Label("Speaker identity is yours to confirm", systemImage: "person.crop.circle.badge.checkmark")
                Label("Sending notes to a vault requires a verified connection", systemImage: "lock.shield")
                Text("Manage and delete remembered voices in People & Voices. Only notes and transcripts are sent through exports; voiceprints are excluded.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Your data") }
            Section { Button("Back to meetings", action: onComplete).buttonStyle(.borderedProminent) }
        }.formStyle(.grouped).navigationTitle("Permissions & Privacy")
    }
    private func permissionRow(_ title: String, icon: String, description: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(description).font(.callout).foregroundStyle(.secondary); Text(status.rawValue).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(status == .granted ? "Allowed" : "Allow", action: action).disabled(status == .granted || status == .restricted || status == .unavailable)
        }.padding(.vertical, 8)
    }
}
#endif
