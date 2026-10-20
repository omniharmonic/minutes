#if canImport(SwiftUI)
import SwiftUI
import MinutesUI

/// Settings for saving meetings to the person's own Parachute vault.
@available(macOS 15.0, iOS 18.0, *)
public struct ParachuteVaultSettings: View {
    @ObservedObject var appState: AppState
    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        Section {
            if let vault = appState.parachuteVault {
                LabeledContent("Vault") {
                    Label("\(vault.vault) · \(vault.origin.host ?? "")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.primary).labelStyle(.titleAndIcon)
                }
                TextField("Folder in vault", text: $appState.parachuteFolder, prompt: Text("Meetings"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                Toggle(isOn: $appState.autoExportParachute) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save each meeting automatically")
                        Text("After its AI summary is ready").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Check Connection") { Task { await appState.verifyParachuteVault() } }
                    Button("Sign Out", role: .destructive) { Task { await appState.disconnectParachuteVault() } }
                    if appState.parachuteBusy { ProgressView().controlSize(.small) }
                }.disabled(appState.parachuteBusy)
            } else {
                TextField("Server", text: $appState.parachuteServer, prompt: Text("parachute.example.com"))
                    .disabled(appState.parachuteBusy)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                HStack {
                    Button(appState.parachuteBusy ? "Waiting for Browser…" : "Sign In…") { appState.connectParachuteVault() }
                        .disabled(appState.parachuteBusy || appState.parachuteServer.trimmingCharacters(in: .whitespaces).isEmpty)
                    if appState.parachuteBusy { Button("Cancel") { appState.cancelParachuteSignIn() } }
                }
            }
            Text(appState.parachuteMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        } header: {
            Text("Parachute vault")
        } footer: {
            Text("Each meeting becomes one note with its summary, transcript and your notes. Exporting again updates that note; edits you make in the vault are never overwritten. Your sign-in is kept in the Keychain on this device.")
        }
    }
}
#endif
