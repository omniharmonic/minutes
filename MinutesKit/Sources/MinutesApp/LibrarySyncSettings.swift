#if canImport(SwiftUI)
import SwiftUI
import MinutesUI

/// Settings for keeping the library the same on the person's Mac and iPhone.
@available(macOS 15.0, iOS 18.0, *)
public struct LibrarySyncSettings: View {
    @ObservedObject var appState: AppState
    @State private var confirmingRemoval = false
    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        Section {
            Toggle(isOn: $appState.iCloudSyncEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync meetings with iCloud")
                    Text("Transcripts, summaries, notes, moments, folders and people").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!appState.librarySyncAvailable)
            if appState.iCloudSyncEnabled {
                Toggle(isOn: $appState.iCloudSyncRecordings) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include recordings")
                        Text("About 1 MB per minute of audio, counted against your iCloud storage").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(appState.librarySyncDescription).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { appState.syncLibraryNow() }
                        .disabled(appState.librarySyncStatus?.phase == .syncing)
                }
                Button("Remove iCloud Copy…", role: .destructive) { confirmingRemoval = true }
                    .confirmationDialog("Remove Minutes data from iCloud?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                        Button("Remove from iCloud", role: .destructive) { Task { await appState.removeLibraryFromICloud() } }
                    } message: {
                        Text("Deletes the synced copy for all your devices and turns sync off here. Meetings on this device are kept. Other devices keep their own copies until you remove them there.")
                    }
            } else {
                Text(appState.librarySyncDescription).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Uses your own private iCloud storage; Minutes has no server. Remembered voices stay on the device that learned them. Turning sync off keeps everything on this device.")
        }
    }
}
#endif
