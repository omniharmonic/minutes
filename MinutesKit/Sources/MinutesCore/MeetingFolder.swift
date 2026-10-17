import Foundation

public struct MeetingFolder: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var description: String
    public var sortOrder: Int
    public let createdAt: Date
    public init(id: String = UUID().uuidString, name: String, description: String = "", sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.description = description; self.sortOrder = sortOrder; self.createdAt = createdAt
    }
}

public enum FolderFilingSource: String, Codable, Sendable { case manual, automatic }

/// An explicit manual Unfiled choice is stored with folderID=nil, not deleted.
public struct MeetingFolderMembership: Codable, Sendable, Equatable {
    public let meetingID: String
    public let folderID: String?
    public let source: FolderFilingSource
    public let revision: Int
    public init(meetingID: String, folderID: String?, source: FolderFilingSource, revision: Int) {
        self.meetingID = meetingID; self.folderID = folderID; self.source = source; self.revision = revision
    }
}

public enum MeetingFolderError: Error, LocalizedError, Sendable {
    case invalidName, descriptionTooLong, missingFolder, missingMeeting
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a folder name between 1 and 120 characters."
        case .descriptionTooLong: "Keep the folder description within 2,000 characters."
        case .missingFolder: "This folder no longer exists. Refresh your library."
        case .missingMeeting: "This meeting no longer exists. Refresh your library."
        }
    }
}
