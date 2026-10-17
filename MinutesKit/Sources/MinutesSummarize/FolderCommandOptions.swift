import Foundation

public struct FolderCommandOptions: Sendable {
    public enum Action: String, Sendable { case list, create, update, delete, move, classify, meetings }
    public let action: Action
    public let targetID: String?
    public let folderID: String?
    public let name: String?
    public let description: String?
    public let apply: Bool
    public init(arguments: [String]) throws {
        guard let first = arguments.first, let action = Action(rawValue: first) else { throw FolderCommandUsage.invalid }
        var values: [String: String] = [:]
        var flags = Set<String>()
        var positional: [String] = []
        var index = 1
        while index < arguments.count {
            let item = arguments[index]
            if ["--name", "--description", "--folder", "--data-dir"].contains(item) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), values[item] == nil else { throw FolderCommandUsage.invalid }
                values[item] = arguments[index + 1]; index += 2
            } else if ["--apply", "--unfiled"].contains(item) {
                guard flags.insert(item).inserted else { throw FolderCommandUsage.invalid }
                index += 1
            } else {
                guard !item.hasPrefix("--") else { throw FolderCommandUsage.invalid }
                positional.append(item); index += 1
            }
        }
        let allowed: Set<String>
        switch action {
        case .list: allowed = []
        case .create: allowed = ["--name", "--description"]
        case .update: allowed = ["--name", "--description"]
        case .delete: allowed = []
        case .move, .meetings: allowed = ["--folder", "--unfiled"]
        case .classify: allowed = ["--apply"]
        }
        let used = Set(values.keys).union(flags).subtracting(["--data-dir"])
        guard used.isSubset(of: allowed) else { throw FolderCommandUsage.invalid }
        let needsID = [.update, .delete, .move, .classify].contains(action)
        guard positional.count == (needsID ? 1 : 0) else { throw FolderCommandUsage.invalid }
        if action == .create, values["--name"] == nil { throw FolderCommandUsage.invalid }
        if action == .update, values["--name"] == nil && values["--description"] == nil { throw FolderCommandUsage.invalid }
        if action == .move || action == .meetings {
            guard (values["--folder"] != nil) != flags.contains("--unfiled") else { throw FolderCommandUsage.invalid }
        }
        self.action = action; targetID = positional.first; folderID = values["--folder"]
        name = values["--name"]; description = values["--description"]; apply = flags.contains("--apply")
    }
}

public enum FolderCommandUsage: Error, LocalizedError {
    case invalid
    public var errorDescription: String? {
        "Usage: minutes-cli folders list; create --name <name> [--description <text>]; update <folder-id> [--name <name>] [--description <text>]; delete <folder-id>; move <meeting-id> --folder <folder-id>|--unfiled; meetings --folder <folder-id>|--unfiled; classify <meeting-id> [--apply]. Add --data-dir <directory> to use an isolated library. Classification uses only installed local sentence models; --apply preserves every manual filing choice."
    }
}
