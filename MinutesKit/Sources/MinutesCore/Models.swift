import Foundation

public struct Meeting: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var platform: String // "zoom", "meet", "teams", "inperson", "import"
    public var calendarEventId: String?
    public var conferenceURL: String?
    public var status: String // "recorded", "transcribing", "diarizing", "needs_review", "summarizing", "finalized", "failed"
    public var device: String?
    public var userNotes: String?
    
    public init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        platform: String = "import",
        calendarEventId: String? = nil,
        conferenceURL: String? = nil,
        status: String = "recorded",
        device: String? = nil,
        userNotes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.platform = platform
        self.calendarEventId = calendarEventId
        self.conferenceURL = conferenceURL
        self.status = status
        self.device = device
        self.userNotes = userNotes
    }
}

public struct Person: Codable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var isMe: Bool
    public var emails: [String]
    public var parachuteNoteId: String?
    
    public init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        displayName: String,
        isMe: Bool = false,
        emails: [String] = [],
        parachuteNoteId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isMe = isMe
        self.emails = emails
        self.parachuteNoteId = parachuteNoteId
    }
}

public struct MeetingAttendee: Codable, Sendable {
    public let meetingId: String
    public let personId: String?
    public let email: String
    public let name: String?
    public let isOrganizer: Bool
    
    public init(meetingId: String, personId: String? = nil, email: String, name: String? = nil, isOrganizer: Bool = false) {
        self.meetingId = meetingId
        self.personId = personId
        self.email = email
        self.name = name
        self.isOrganizer = isOrganizer
    }
}

public struct SpeakerCluster: Codable, Sendable, Identifiable {
    public let id: String
    public let meetingId: String
    public let trackId: String
    public var label: String // "Speaker 1", "Speaker 2", "Me"
    public var centroid: [Float] // WeSpeaker embedding vector
    public var speechSeconds: Double
    public var personId: String?
    public var assignment: String // "auto", "suggested", "user", "me_channel"
    public var confidence: Double
    
    public init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        meetingId: String,
        trackId: String,
        label: String,
        centroid: [Float] = [],
        speechSeconds: Double = 0.0,
        personId: String? = nil,
        assignment: String = "suggested",
        confidence: Double = 0.0
    ) {
        self.id = id
        self.meetingId = meetingId
        self.trackId = trackId
        self.label = label
        self.centroid = centroid
        self.speechSeconds = speechSeconds
        self.personId = personId
        self.assignment = assignment
        self.confidence = confidence
    }
}

public struct WordTiming: Codable, Sendable {
    public let word: String
    public let start: Double
    public let end: Double
    public let confidence: Double
    
    public init(word: String, start: Double, end: Double, confidence: Double = 1.0) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct Utterance: Codable, Sendable, Identifiable {
    public let id: Int
    public let meetingId: String
    public var clusterId: String
    public var speakerName: String
    public let start: Double
    public let end: Double
    public let text: String
    public var words: [WordTiming]
    
    public init(
        id: Int,
        meetingId: String,
        clusterId: String,
        speakerName: String,
        start: Double,
        end: Double,
        text: String,
        words: [WordTiming] = []
    ) {
        self.id = id
        self.meetingId = meetingId
        self.clusterId = clusterId
        self.speakerName = speakerName
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct ActionItem: Codable, Sendable {
    public let text: String
    public let owner: String?
    public let due: String?
    
    public init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

public struct Topic: Codable, Sendable {
    public let title: String
    public let discussion: String
    
    public init(title: String, discussion: String) {
        self.title = title
        self.discussion = discussion
    }
}

public struct MeetingSummary: Codable, Sendable {
    public let meetingId: String
    public var title: String
    public var overview: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var topics: [Topic]
    public var questions: [String]
    public var markdown: String
    
    public init(
        meetingId: String,
        title: String,
        overview: String,
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        topics: [Topic] = [],
        questions: [String] = [],
        markdown: String = ""
    ) {
        self.meetingId = meetingId
        self.title = title
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.topics = topics
        self.questions = questions
        self.markdown = markdown
    }
}

public struct Voiceprint: Codable, Sendable, Identifiable {
    public let id: String
    public let personId: String
    public let model: String // "wespeaker_v2"
    public let dim: Int
    public let vector: [Float] // L2-normalized
    public let speechSeconds: Double
    public let createdAt: Date
    
    public init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        personId: String,
        model: String = "wespeaker_v2",
        dim: Int = 256,
        vector: [Float],
        speechSeconds: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.personId = personId
        self.model = model
        self.dim = dim
        self.vector = vector
        self.speechSeconds = speechSeconds
        self.createdAt = createdAt
    }
}
