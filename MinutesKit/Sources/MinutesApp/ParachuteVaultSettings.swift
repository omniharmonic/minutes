#if canImport(SwiftUI)
import SwiftUI
import MinutesUI
import MinutesExport

/// Settings for saving meetings to the person's own Parachute vault.
@available(macOS 15.0, iOS 18.0, *)
public struct ParachuteVaultSettings: View {
    @ObservedObject var appState: AppState
    public init(appState: AppState) { self.appState = appState }

    private func signIn() {
        guard !appState.parachuteServer.trimmingCharacters(in: .whitespaces).isEmpty else {
            appState.parachuteMessage = "Enter your Parachute server's address first, for example agent.example.com."
            return
        }
        appState.connectParachuteVault()
    }

    public var body: some View {
        Section {
            if let vault = appState.parachuteVault {
                LabeledContent("Vault") {
                    Label("\(vault.vault) · \(vault.origin.host ?? "")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.primary).labelStyle(.titleAndIcon)
                }
                TextField("Folder in vault", text: $appState.parachuteFolder, prompt: Text(ParachuteMeetingNote.defaultFolder))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                Toggle(isOn: $appState.autoExportParachute) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save each meeting automatically")
                        Text("When its summary is ready, from the device that recorded it. Renaming speakers later updates the note.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Check Connection") { Task { await appState.verifyParachuteVault() } }
                    Button("Sign Out", role: .destructive) { Task { await appState.disconnectParachuteVault() } }
                    if appState.parachuteBusy { ProgressView().controlSize(.small) }
                }.disabled(appState.parachuteBusy)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Parachute server")
                    TextField("Your Parachute server", text: $appState.parachuteServer, prompt: Text("e.g. agent.example.com"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.parachuteBusy)
                        .onSubmit { signIn() }
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        #endif
                    Text("The address you open Parachute at. You'll choose the vault on its sign-in page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(appState.parachuteBusy ? "Waiting for Browser…" : "Sign In…") { signIn() }
                        .disabled(appState.parachuteBusy)
                    if appState.parachuteBusy { Button("Cancel") { appState.cancelParachuteSignIn() } }
                }
            }
            Text(appState.parachuteMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        } header: {
            Text("Parachute vault")
        } footer: {
            Text("Each meeting becomes one note with its summary, transcript and your notes, shared by all your devices: iCloud sync tells each device which note a meeting already has, so nothing is saved twice. Once you or an agent change a note in the vault, Minutes stops updating it. Sign in on each device that records; the sign-in stays in this device's Keychain.")
        }
    }
}
#endif
