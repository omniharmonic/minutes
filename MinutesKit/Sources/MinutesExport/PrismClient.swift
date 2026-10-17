import Foundation
import CryptoKit
import MinutesCore

// MARK: - PR-B Integration Contracts

public struct PrismCalendarContext: Codable, Sendable, Equatable {
    public let provider: String
    public let calendarId: String
    public let eventId: String
    public let iCalUID: String?
    public let originalStartTime: String?
    
    public init(
        provider: String,
        calendarId: String,
        eventId: String,
        iCalUID: String? = nil,
        originalStartTime: String? = nil
    ) {
        self.provider = provider
        self.calendarId = calendarId
        self.eventId = eventId
        self.iCalUID = iCalUID
        self.originalStartTime = originalStartTime
    }
}

public struct PrismPersonContext: Codable, Sendable, Equatable {
    public let sourcePersonId: String
    public let displayName: String
    public let emails: [String]
    public let attendance: String // "confirmed", "invited", "unknown"
    
    public init(
        sourcePersonId: String,
        displayName: String,
        emails: [String],
        attendance: String = "confirmed"
    ) {
        self.sourcePersonId = sourcePersonId
        self.displayName = displayName
        self.emails = emails
        self.attendance = attendance
    }
}

public struct PrismUtteranceContext: Codable, Sendable, Equatable {
    public let id: String
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let speakerPersonId: String?
    public let assignment: String // "user", "model", "unassigned"
    
    public init(
        id: String,
        startMs: Int,
        endMs: Int,
        text: String,
        speakerPersonId: String?,
        assignment: String = "user"
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerPersonId = speakerPersonId
        self.assignment = assignment
    }
}

public struct PrismSummaryContext: Codable, Sendable, Equatable {
    public let markdown: String
    public let status: String // "completed", "partial", "not_generated"
    public let evidence: [String]
    
    public init(
        markdown: String,
        status: String = "completed",
        evidence: [String] = []
    ) {
        self.markdown = markdown
        self.status = status
        self.evidence = evidence
    }
}

public struct PrismMeetingPayload: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sourceMeetingId: String
    public let sourceRevision: Int
    public let title: String
    public let startedAt: String // ISO8601
    public let endedAt: String? // ISO8601
    public let timeZone: String
    public let calendar: PrismCalendarContext?
    public let people: [PrismPersonContext]
    public let utterances: [PrismUtteranceContext]
    public let notesMarkdown: String
    public let summary: PrismSummaryContext
    public let contentHash: String
    
    public init(
        schemaVersion: Int = 1,
        sourceMeetingId: String,
        sourceRevision: Int = 1,
        title: String,
        startedAt: String,
        endedAt: String?,
        timeZone: String,
        calendar: PrismCalendarContext? = nil,
        people: [PrismPersonContext],
        utterances: [PrismUtteranceContext],
        notesMarkdown: String,
        summary: PrismSummaryContext,
        contentHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceMeetingId = sourceMeetingId
        self.sourceRevision = sourceRevision
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZone = timeZone
        self.calendar = calendar
        self.people = people
        self.utterances = utterances
        self.notesMarkdown = notesMarkdown
        self.summary = summary
        self.contentHash = contentHash
    }
    
    public static func computeContentHash(
        title: String,
        startedAt: String,
        people: [PrismPersonContext],
        utterances: [PrismUtteranceContext],
        notesMarkdown: String,
        summaryMarkdown: String
    ) -> String {
        // Encode structured content: delimiters and unchanged word counts must not
        // make two different transcripts (or identity corrections) look identical.
        struct Content: Encodable {
            let title: String
            let startedAt: String
            let people: [PrismPersonContext]
            let utterances: [PrismUtteranceContext]
            let notesMarkdown: String
            let summaryMarkdown: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let content = Content(title: title, startedAt: startedAt, people: people,
            utterances: utterances, notesMarkdown: notesMarkdown, summaryMarkdown: summaryMarkdown)
        // These fields contain only strings, integer timestamps, and arrays.
        let canonical = try! encoder.encode(content)
        let digest = SHA256.hash(data: canonical)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct PrismImportResponse: Codable, Sendable {
    public let status: String // "committed" or "pending"
    public let importId: String
    public let meetingNoteId: String?
    public let transcriptNoteId: String?
    public let sourceRevision: Int?
    public let serverRevision: Int?
    public let viewUrl: String?
    public let warnings: [String]?
    
    public init(
        status: String = "committed",
        importId: String,
        meetingNoteId: String? = nil,
        transcriptNoteId: String? = nil,
        sourceRevision: Int? = nil,
        serverRevision: Int? = nil,
        viewUrl: String? = nil,
        warnings: [String]? = nil
    ) {
        self.status = status
        self.importId = importId
        self.meetingNoteId = meetingNoteId
        self.transcriptNoteId = transcriptNoteId
        self.sourceRevision = sourceRevision
        self.serverRevision = serverRevision
        self.viewUrl = viewUrl
        self.warnings = warnings
    }
}

// MARK: - Prism Errors

public enum PrismError: Error, LocalizedError, Sendable {
    case acceptedPending(importId: String)
    case needsSignIn(String)
    case forbidden(String)
    case conflict(serverRevision: Int?, message: String)
    case failedRetryable(statusCode: Int, message: String)
    case invalidPayload(String)
    case unhandledResponse(statusCode: Int, message: String)
    
    public var errorDescription: String? {
        switch self {
        case .acceptedPending(let importId):
            return "Accepted by Prism; awaiting committed receipt for \(importId)"
        case .needsSignIn(let msg):
            return "Sign-in required: \(msg)"
        case .forbidden(let msg):
            return "Forbidden: \(msg)"
        case .conflict(_, let msg):
            return "Conflict: \(msg)"
        case .failedRetryable(let code, let msg):
            return "Retryable error (\(code)): \(msg)"
        case .invalidPayload(let msg):
            return "Invalid payload: \(msg)"
        case .unhandledResponse(let code, let msg):
            return "Unhandled response (\(code)): \(msg)"
        }
    }
}

// MARK: - Prism Client Protocol & Implementation

public protocol PrismClientProtocol: Sendable {
    func uploadMeeting(
        payload: PrismMeetingPayload,
        destinationVault: String,
        idempotencyKey: String,
        baseRevision: Int?
    ) async throws -> PrismReceipt
}

public final class PrismClient: PrismClientProtocol {
    public let baseURL: URL
    public let session: URLSession
    public let tokenProvider: @Sendable () async -> String?
    
    public init(
        baseURL: URL,
        session: URLSession? = nil,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.baseURL = baseURL
        self.session = session ?? ExportHTTPTransport.makeSession()
        self.tokenProvider = tokenProvider
    }
    
    public func uploadMeeting(
        payload: PrismMeetingPayload,
        destinationVault: String,
        idempotencyKey: String,
        baseRevision: Int? = nil
    ) async throws -> PrismReceipt {
        do {try ExportHTTPTransport.validateOrigin(baseURL)} catch {throw PrismError.invalidPayload("Use a secure Prism origin without embedded credentials")}
        guard payload.sourceMeetingId.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else {throw PrismError.invalidPayload("Invalid source meeting identifier")}
        guard let token = await tokenProvider() else {
            throw PrismError.needsSignIn("Missing authentication token")
        }
        
        let path = "/api/integrations/minutes/meetings/\(payload.sourceMeetingId)"
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw PrismError.invalidPayload("Malformed endpoint URL: \(path)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(destinationVault, forHTTPHeaderField: "X-Prism-Vault")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let baseRev = baseRevision {
            request.setValue("\"\(baseRev)\"", forHTTPHeaderField: "If-Match")
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(payload)
        } catch {
            throw PrismError.invalidPayload("Payload serialization failed: \(error.localizedDescription)")
        }
        request.httpBody = bodyData
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PrismError.failedRetryable(statusCode: 0, message: "Network connection failed: \(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrismError.failedRetryable(statusCode: 0, message: "Non-HTTP response received")
        }
        
        let statusCode = httpResponse.statusCode
        // Error bodies may contain private server data or reflected credentials. Never persist them in outbox diagnostics.
        
        switch statusCode {
        case 200, 201:
            // Committed
            let decoded: PrismImportResponse
            do {
                decoded = try JSONDecoder().decode(PrismImportResponse.self, from: data)
            } catch {
                throw PrismError.unhandledResponse(statusCode: statusCode, message: "Malformed response JSON: \(error.localizedDescription)")
            }
            guard decoded.status == "committed", !decoded.importId.isEmpty,
                  let meetingNoteId = decoded.meetingNoteId, !meetingNoteId.isEmpty,
                  let transcriptNoteId = decoded.transcriptNoteId, !transcriptNoteId.isEmpty,
                  let revision = decoded.serverRevision, revision > 0 else {
                throw PrismError.unhandledResponse(statusCode: statusCode, message: "Missing committed receipt fields")
            }
            return PrismReceipt(
                importId: decoded.importId,
                meetingNoteId: meetingNoteId,
                transcriptNoteId: transcriptNoteId,
                serverRevision: revision,
                contentHash: payload.contentHash,
                committedAt: Date()
            )
            
        case 202:
            // Accepted / Pending
            guard let decoded = try? JSONDecoder().decode(PrismImportResponse.self, from: data),
                  !decoded.importId.isEmpty else {
                throw PrismError.unhandledResponse(statusCode: 202, message: "Missing pending import identifier")
            }
            throw PrismError.acceptedPending(importId: decoded.importId)
            
        case 401:
            throw PrismError.needsSignIn("Authentication required or expired token")
            
        case 403:
            throw PrismError.forbidden("Access denied to the selected destination vault")
            
        case 409:
            // Extract server revision if present
            var serverRev: Int? = nil
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rev = obj["serverRevision"] as? Int {
                serverRev = rev
            }
            throw PrismError.conflict(serverRevision: serverRev, message: "Meeting conflict detected on server")
            
        case 400, 422:
            throw PrismError.invalidPayload("Rejected payload (\(statusCode))")
            
        case 408, 429, 500, 502, 503, 504:
            throw PrismError.failedRetryable(statusCode: statusCode, message: "Transient server error")
            
        default:
            throw PrismError.unhandledResponse(statusCode: statusCode, message: "Unexpected server status")
        }
    }
}
