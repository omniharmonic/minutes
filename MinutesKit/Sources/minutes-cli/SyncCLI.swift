import Foundation
import MinutesCore
import MinutesSync

/// `minutes-cli sync …`: inspect what iCloud sync would exchange. Sending runs in
/// the signed app, which holds the iCloud entitlement a command-line tool cannot.
enum SyncCLI {
    static func run(arguments: [String], store: MinutesStore, audioDirectory: URL?) throws {
        let library = SyncLibrary(store: store, audioDirectory: arguments.contains("--recordings") ? audioDirectory : nil)
        switch arguments.count > 2 ? arguments[2] : "" {
        case "status":
            let changes = try library.pendingChanges()
            let synced = try store.listSyncRecordNames().count
            print("\(synced) records agreed with iCloud; \(changes.count) local changes waiting.")
            print("Sync runs inside Minutes.app (Settings → Sync); the CLI cannot use the iCloud entitlement.")
        case "pending":
            for change in try library.pendingChanges() {
                switch change {
                case .save(let name): print("upload  \(name)")
                case .delete(let name): print("delete  \(name)")
                }
            }
        case "payload":
            guard arguments.count > 3, let name = SyncRecordName(arguments[3]) else { print("Usage: minutes-cli sync payload Meeting:<id>|Folder:<id>|Person:<id>"); exit(1) }
            guard let payload = try library.localPayload(name) else { print("No local record \(name)."); exit(1) }
            print(String(decoding: payload, as: UTF8.self))
        case "reset":
            try store.resetSyncRecordStates()
            print("Forgot what was agreed with iCloud. The app will compare and merge everything on its next sync; nothing local is deleted.")
        default:
            print("Usage: minutes-cli sync status|pending|payload <record>|reset [--recordings] [--data-dir <path>]")
            exit(1)
        }
    }
}
