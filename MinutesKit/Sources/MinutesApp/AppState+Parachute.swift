#if canImport(SwiftUI)
import Foundation
import MinutesCore
import MinutesExport

/// Direct export to a Parachute vault the person signed in to from Settings.
extension AppState {
    func configuredParachuteConnection() throws -> ParachuteVaultConnection {
        if let parachuteConnection { return parachuteConnection }
        let connection = try ParachuteVaultConnection(origin: ParachuteVaultConnection.normalizedOrigin(parachuteServer))
        parachuteConnection = connection
        return connection
    }

    /// Reads the saved sign-in without prompting; nothing is sent to the server.
    public func restoreParachuteVault() async {
        guard !parachuteServer.isEmpty, parachuteVault == nil else { return }
        do {
            parachuteVault = try await configuredParachuteConnection().status(allowInteraction: false)
            if let vault = parachuteVault {
                parachuteMessage = "Saving to “\(vault.vault)” on \(vault.origin.host ?? "your server")."
                await saveQueuedParachuteMeetings()
            }
        } catch { parachuteMessage = "Sign in again to keep saving to your vault." }
    }

    public func connectParachuteVault() {
        guard !parachuteBusy else { return }
        parachuteBusy = true
        parachuteMessage = "Finish signing in in your browser, then choose the vault Minutes may write to."
        parachuteSignIn = Task {
            defer { parachuteBusy = false; parachuteSignIn = nil }
            do {
                parachuteServer = try ParachuteVaultConnection.normalizedOrigin(parachuteServer).absoluteString
                let connection = try configuredParachuteConnection()
                let browser = OAuthSystemBrowserSession()
                let status = try await connection.connect { url, receiver, state in
                    try await browser.authorize(url: url, loopback: receiver, expectedState: state)
                }
                parachuteVault = status
                autoExportParachute = true
                parachuteMessage = "Connected. Meetings you export are saved to “\(status.vault)” in \(parachuteFolder.isEmpty ? "the vault’s top level" : parachuteFolder)."
                await saveQueuedParachuteMeetings()
            } catch is CancellationError {
                parachuteMessage = "Sign-in cancelled."
            } catch OAuthError.cancelled {
                parachuteMessage = "Sign-in cancelled."
            } catch {
                parachuteMessage = "Couldn’t sign in: \(error.localizedDescription)"
            }
        }
    }

    public func cancelParachuteSignIn() { parachuteSignIn?.cancel() }

    public func verifyParachuteVault() async {
        guard !parachuteBusy else { return }
        parachuteBusy = true; defer { parachuteBusy = false }
        do {
            parachuteVault = try await configuredParachuteConnection().verify()
            parachuteMessage = "Connected to “\(parachuteVault!.vault)”. The vault answered just now."
        } catch { parachuteMessage = "Vault check failed: \(error.localizedDescription)" }
    }

    public func disconnectParachuteVault() async {
        guard let connection = try? configuredParachuteConnection() else { parachuteVault = nil; return }
        parachuteBusy = true; defer { parachuteBusy = false }
        await connection.disconnect()
        parachuteVault = nil; autoExportParachute = false
        parachuteMessage = "Signed out. Notes already in your vault are unchanged."
    }

    /// Saves one meeting's transcript, summary and notes as a vault note, updating
    /// the note from an earlier export (on any device) rather than creating a second one.
    public func saveToParachuteVault(meetingID: String) async throws -> ExportResult {
        guard let vault = parachuteVault else { throw ParachuteVaultError.notConnected }
        guard let meeting = store.getMeeting(id: meetingID) else { throw ParachuteVaultError.notConnected }
        // One save per meeting at a time, so two exports cannot both create a note.
        while parachuteSavesInFlight.contains(meetingID) { try await Task.sleep(for: .milliseconds(100)) }
        parachuteSavesInFlight.insert(meetingID)
        defer { parachuteSavesInFlight.remove(meetingID) }
        let clusters = store.listSpeakerClusters(meetingId: meetingID)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: store.listPeopleForMeeting(meetingId: meetingID), clusters: clusters,
            utterances: TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meetingID), clusters: clusters),
            summary: store.getSummary(meetingId: meetingID))
        let key = ParachuteMeetingNote.receiptKey(vaultURL: vault.vaultURL, meetingID: meetingID)
        // The receipt arrives through iCloud when another device saved this meeting.
        let previous = try store.librarySetting(key).flatMap { try? JSONDecoder().decode(ParachuteNoteReceipt.self, from: Data($0.utf8)) }
        let receipt = try await ParachuteMeetingNote.save(bundle, folder: parachuteFolder, previous: previous, using: configuredParachuteConnection())
        if receipt != previous {
            try store.setParachuteReceipt(key: key, value: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self), meetingID: meetingID)
            syncLibraryNow()
        }
        parachuteMessage = "Saved “\(meeting.title)” to \(vault.vault)."
        return ExportResult(adapterId: "parachute", externalRef: receipt.id, pathOrURL: vault.vaultURL.absoluteString, success: true)
    }

    static let parachutePendingPrefix = "parachute-pending:"

    /// Runs after a summary is saved on the device that recorded the meeting.
    /// Delivery problems never fail processing; the meeting waits in a queue.
    func automaticallyExportToParachute(meetingID: String) async {
        guard autoExportParachute, let meeting = store.getMeeting(id: meetingID),
              !["failed", "interrupted", "recording", "processing"].contains(meeting.status),
              store.getSummary(meetingId: meetingID) != nil, !store.listUtterances(meetingId: meetingID).isEmpty else { return }
        await queueParachuteSave(meetingID: meetingID)
    }

    /// Keeps a note that is already in the vault current after names or the
    /// summary change, from whichever device made the change.
    func refreshParachuteNoteIfSaved(meetingID: String) async {
        guard let vault = parachuteVault,
              (try? store.librarySetting(ParachuteMeetingNote.receiptKey(vaultURL: vault.vaultURL, meetingID: meetingID))) != nil
                || autoExportParachute else { return }
        guard store.getSummary(meetingId: meetingID) != nil else { return }
        await queueParachuteSave(meetingID: meetingID)
    }

    /// Remembers the meeting until it reaches the vault (survives quitting and
    /// being offline), then tries now.
    func queueParachuteSave(meetingID: String) async {
        try? store.setLibrarySetting(Self.parachutePendingPrefix + meetingID, value: ISO8601DateFormatter().string(from: Date()))
        await saveQueuedParachuteMeetings()
    }

    /// Delivers waiting meetings. Called after sign-in, at launch and after sync.
    public func saveQueuedParachuteMeetings() async {
        guard parachuteVault != nil, !parachuteQueueRunning else { return }
        parachuteQueueRunning = true; defer { parachuteQueueRunning = false }
        let pending = (try? store.librarySettings(prefix: Self.parachutePendingPrefix)) ?? []
        var failures = 0
        for entry in pending {
            let meetingID = String(entry.key.dropFirst(Self.parachutePendingPrefix.count))
            guard store.getMeeting(id: meetingID) != nil else { try? store.setLibrarySetting(entry.key, value: nil); continue }
            do {
                _ = try await saveToParachuteVault(meetingID: meetingID)
                try? store.setLibrarySetting(entry.key, value: nil)
            } catch ParachuteVaultError.editedInVault {
                // A person or agent has the note now; Minutes stops updating it.
                try? store.setLibrarySetting(entry.key, value: nil)
                parachuteMessage = ParachuteVaultError.editedInVault.localizedDescription
            } catch ParachuteVaultError.signInExpired {
                parachuteMessage = "Sign in to your vault again; \(pending.count) meeting(s) are waiting to be saved."
                return
            } catch {
                failures += 1
                parachuteMessage = "Transcript and summary are saved here. \(failures) meeting(s) will be saved to your vault when it can be reached: \(error.localizedDescription)"
            }
        }
    }

    /// After a speaker is named or changed: carry the names into the summary
    /// (only generic labels such as “Speaker 2”), then keep the vault note current.
    /// `before` is the readable transcript as it was before the change.
    public func speakersChanged(meetingID: String, before: [Utterance]) {
        let clusters = store.listSpeakerClusters(meetingId: meetingID)
        let after = TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meetingID), clusters: clusters)
        let renames = SummarySpeakerNames.renames(before: before, after: after)
        if let summary = store.getSummary(meetingId: meetingID), let updated = SummarySpeakerNames.apply(renames, to: summary) {
            do {
                try store.saveSummary(updated)
                if currentMeeting?.id == meetingID { currentSummary = updated }
            } catch { statusMessage = "Speaker names saved; the summary could not be updated: \(error.localizedDescription)" }
        }
        syncLibraryNow()
        Task { await refreshParachuteNoteIfSaved(meetingID: meetingID) }
    }
}
#endif
