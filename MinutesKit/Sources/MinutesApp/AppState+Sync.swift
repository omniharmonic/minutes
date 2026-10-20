#if canImport(SwiftUI)
import Foundation
import Combine
import MinutesCore
import MinutesSync

/// iCloud sync between the person's own devices. It runs only in builds signed
/// with the iCloud entitlement, which also carry `MinutesCloudKitContainer`.
extension AppState {
    /// The iCloud container this build is entitled to, or nil (CloudKit would crash without it).
    public static var cloudKitContainerIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MinutesCloudKitContainer") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    public var librarySyncAvailable: Bool { Self.cloudKitContainerIdentifier != nil }

    public var librarySyncDescription: String {
        guard librarySyncAvailable else { return "iCloud sync isn’t included in this build of Minutes." }
        guard iCloudSyncEnabled else { return "Meetings stay on this device." }
        guard let status = librarySyncStatus else { return "Starting…" }
        switch status.phase {
        case .syncing: return "Syncing…"
        case .signedOut: return "Sign in to iCloud in System Settings to sync."
        case .failed(let message): return "Sync paused: \(message)"
        case .removedFromICloud: return "Turned off: the iCloud copy was removed."
        case .idle:
            let when = status.lastSynced.map { "Up to date as of \($0.formatted(date: .omitted, time: .shortened))." } ?? "Up to date."
            return status.pendingCount > 0 ? "\(status.pendingCount) changes waiting to upload." : when
        }
    }

    func librarySyncSettingChanged(from oldValue: Bool) {
        guard oldValue != iCloudSyncEnabled else { return }
        iCloudSyncEnabled ? startLibrarySyncIfEnabled() : stopLibrarySync()
    }

    func restartLibrarySync() {
        guard iCloudSyncEnabled else { return }
        stopLibrarySync(); startLibrarySyncIfEnabled()
    }

    public func startLibrarySyncIfEnabled() {
        guard iCloudSyncEnabled, librarySync == nil, let container = Self.cloudKitContainerIdentifier else { return }
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let sync = CloudKitLibrarySync(containerIdentifier: container, store: store,
            audioDirectory: iCloudSyncRecordings ? managedAudioDirectory : nil,
            onLibraryChanged: { [weak self] in Task { @MainActor in self?.reloadAfterSync() } },
            onStatus: { [weak self] status in Task { @MainActor in
                guard let self else { return }
                if status.phase == .removedFromICloud {
                    self.iCloudSyncEnabled = false
                    self.statusMessage = "Sync was turned off because Minutes data was removed from iCloud on another device. Meetings here are unchanged."
                } else { self.librarySyncStatus = status }
            } })
        librarySync = sync
        Task { await sync.start() }
        // Without push notifications, check every few minutes while the app runs.
        librarySyncTimer = Timer.publish(every: 180, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.syncLibraryNow() }
    }

    public func syncLibraryNow() {
        guard #available(macOS 14.0, iOS 17.0, *), let sync = librarySync as? CloudKitLibrarySync,
              !isRecording, !isProcessing else { return }
        Task { await sync.syncNow() }
    }

    /// Deletes the library from the person's iCloud (all devices) and turns sync off here.
    public func removeLibraryFromICloud() async {
        guard #available(macOS 14.0, iOS 17.0, *), let sync = librarySync as? CloudKitLibrarySync else { return }
        do {
            try await sync.deleteCloudCopy()
            iCloudSyncEnabled = false
            statusMessage = "Removed Minutes data from iCloud. Meetings on this device are unchanged."
        } catch { statusMessage = "Could not remove the iCloud copy: \(error.localizedDescription)" }
    }

    func stopLibrarySync() {
        librarySyncTimer?.cancel(); librarySyncTimer = nil
        if #available(macOS 14.0, iOS 17.0, *), let sync = librarySync as? CloudKitLibrarySync { Task { await sync.stop() } }
        librarySync = nil
        librarySyncStatus = nil
    }

    /// Changes from another device: refresh lists and the open meeting.
    func reloadAfterSync() {
        meetings = store.listMeetings()
        reloadFolderLibrary()
        if let id = selectedMeetingId, store.getMeeting(id: id) != nil, !isRecording { selectMeeting(id: id) }
    }
}
#endif
