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
            if let vault = parachuteVault { parachuteMessage = "Saving to “\(vault.vault)” on \(vault.origin.host ?? "your server")." }
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
                parachuteMessage = "Connected. Meetings you export are saved to “\(status.vault)” in \(parachuteFolder.isEmpty ? "the vault’s top level" : parachuteFolder)."
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
    /// the note from an earlier export rather than creating a second one.
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
        let previous = try store.librarySetting(key).flatMap { try? JSONDecoder().decode(ParachuteNoteReceipt.self, from: Data($0.utf8)) }
        let receipt = try await ParachuteMeetingNote.save(bundle, folder: parachuteFolder, previous: previous, using: configuredParachuteConnection())
        try store.setLibrarySetting(key, value: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
        parachuteMessage = "Saved “\(meeting.title)” to \(vault.vault)."
        return ExportResult(adapterId: "parachute", externalRef: receipt.id, pathOrURL: vault.vaultURL.absoluteString, success: true)
    }

    /// Runs only after a real AI summary was saved; delivery problems never fail processing.
    func automaticallyExportToParachute(meetingID: String) async {
        guard autoExportParachute, parachuteVault != nil, let meeting = store.getMeeting(id: meetingID),
              !["failed", "interrupted", "recording", "processing"].contains(meeting.status),
              store.getSummary(meetingId: meetingID) != nil, !store.listUtterances(meetingId: meetingID).isEmpty else { return }
        do { _ = try await saveToParachuteVault(meetingID: meetingID) }
        catch { parachuteMessage = "Transcript and summary are saved here. Saving to your vault needs attention: \(error.localizedDescription)" }
    }
}
#endif
