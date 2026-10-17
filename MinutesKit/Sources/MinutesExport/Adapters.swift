import Foundation
import CryptoKit
import MinutesCore

public struct MeetingExportBundle: Sendable {
    public let meeting: Meeting
    public let attendees: [Person]
    public let clusters: [SpeakerCluster]
    public let utterances: [Utterance]
    public let summary: MeetingSummary?
    public let destinationDirectory: String?
    
    public init(
        meeting: Meeting,
        attendees: [Person],
        clusters: [SpeakerCluster],
        utterances: [Utterance],
        summary: MeetingSummary?,
        destinationDirectory: String? = nil
    ) {
        self.meeting = meeting
        self.attendees = attendees
        self.clusters = clusters
        self.utterances = utterances
        self.summary = summary
        self.destinationDirectory = destinationDirectory
    }
}

public struct ExportResult: Sendable {
    public let adapterId: String
    public let externalRef: String?
    public let pathOrURL: String?
    public let success: Bool
    public let error: String?
    
    public init(adapterId: String, externalRef: String? = nil, pathOrURL: String? = nil, success: Bool = true, error: String? = nil) {
        self.adapterId = adapterId
        self.externalRef = externalRef
        self.pathOrURL = pathOrURL
        self.success = success
        self.error = error
    }
}

public protocol ExportAdapter: Sendable {
    static var id: String { get }
    var displayName: String { get }
    func export(bundle: MeetingExportBundle) async throws -> ExportResult
}

// MARK: - MarkdownAdapter

public final class MarkdownAdapter: ExportAdapter {
    public static let id = "markdown"
    public let displayName = "Obsidian Markdown"
    public let outputDirectory: String
    
    public init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
    }
    
    public func export(bundle: MeetingExportBundle) async throws -> ExportResult {
        let filename = "minutes-\(exportIdentity(bundle.meeting.id)).md"
        let outPath = (outputDirectory as NSString).appendingPathComponent(filename)
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let content = Self.render(bundle: bundle)
        try content.write(toFile: outPath, atomically: true, encoding: .utf8)
        return ExportResult(adapterId: Self.id, externalRef: bundle.meeting.id, pathOrURL: outPath, success: true)
    }
    /// The same complete document is used by CLI export and native Save As.
    public static func render(bundle: MeetingExportBundle) -> String {
        let m = bundle.meeting
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFmt.string(from: m.startedAt)
        // Front-matter
        var content = "---\n"
        content += "title: \(yamlString(m.title))\n"
        content += "date: \(dateStr)\n"
        content += "tags: [meeting]\n"
        content += "minutes_id: \(yamlString(m.id))\n"
        if !bundle.attendees.isEmpty {
            let wikilinks = bundle.attendees.map { yamlString("[[\($0.displayName)]]") }.joined(separator: ", ")
            content += "attendees: [\(wikilinks)]\n"
        }
        content += "---\n\n"
        
        if let notes=m.userNotes, !notes.isEmpty { content += "## Your notes\n\(notes)\n\n" }
        if let summary = bundle.summary {
            content += summary.markdown
            // Summary content stays concise; exports retain the complete source separately.
            if !summary.markdown.contains("\n## Transcript\n") && !bundle.utterances.isEmpty {
                content += "\n\n## Transcript\n\n"
                for (index, utterance) in bundle.utterances.enumerated() {
                    let reference = String(format: "T%04d", index + 1)
                    let timing = m.platform == "transcript_import" ? "untimed" : String(format: "%.3f–%.3f s", utterance.start, utterance.end)
                    content += "[\(reference)] **\(utterance.speakerName)** (\(timing)): \(utterance.text)\n\n"
                }
            }
        } else {
            content += "# \(m.title)\n\n"
            for u in bundle.utterances {
                content += "**\(u.speakerName)**: \(u.text)\n\n"
            }
        }
        
        return content
    }

}

// MARK: - ParachuteAdapter

public final class ParachuteAdapter: ExportAdapter {
    public static let id = "parachute"
    public let displayName = "Parachute (legacy macOS CLI export)"
    public let vaultHost: String // e.g. "http://localhost:1940"
    public let vaultName: String // "default"
    public let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    
    public init(
        vaultHost: String = "http://127.0.0.1:1940",
        vaultName: String = "default",
        tokenProvider: (@Sendable () -> String?)? = nil,
        session: URLSession? = nil
    ) {
        self.session = session ?? ExportHTTPTransport.makeSession()
        self.vaultHost = vaultHost
        self.vaultName = vaultName
        self.tokenProvider = tokenProvider ?? { ParachuteAdapter.mintTokenFromCLI() }
    }
    
    public static func mintTokenFromCLI() -> String? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; command -v parachute >/dev/null 2>&1 && parachute auth mint-token --scope vault:default:write --ephemeral || ($HOME/.bun/bin/parachute auth mint-token --scope vault:default:write --ephemeral 2>/dev/null)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t = token, !t.isEmpty, t.starts(with: "ey") {
                return t
            }
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
    
    public func export(bundle: MeetingExportBundle) async throws -> ExportResult {
        try ExportHTTPTransport.validateOrigin(URL(string:vaultHost))
        guard vaultName.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else {throw LegacyExportError.invalidDestination}
        guard let token = tokenProvider() else {
            return ExportResult(adapterId: Self.id, success: false, error: "Failed to mint or acquire Parachute token")
        }
        
        let m = bundle.meeting
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFmt.string(from: m.startedAt)
        
        let meetingPath = "vault/meetings/minutes-\(exportIdentity(m.id))"

        // 1. Ensure Person notes exist for attendees
        var personNoteIds: [String] = []
        for attendee in bundle.attendees {
            let personPath = "vault/people/minutes-\(exportIdentity(attendee.id))"

            let personBody: [String: Any] = [
                "path": personPath,
                "content": "# \(attendee.displayName)\n\nPerson record for \(attendee.displayName).",
                "tags": ["person"],
                "metadata": [
                    "displayName": attendee.displayName,
                    "emails": attendee.emails,
                    "source": "minutes",
                    "minutes_person_id": attendee.id
                ],
                "if_exists": "ignore"
            ]
            
            if let noteId = try await postNote(body: personBody, token: token) {
                personNoteIds.append(noteId)
            }
        }
        
        // 2. Create Meeting note
        let transcript = bundle.utterances.map { "**\($0.speakerName)**: \($0.text)" }.joined(separator:"\n\n")
        let userNotes = m.userNotes.map { "## Your notes\n\($0)\n\n" } ?? ""
        let markdownContent = userNotes + (bundle.summary?.markdown ?? "# \(m.title)\n\n\(transcript)")
        let attendeeNames = bundle.attendees.map { $0.displayName }
        let attendeeEmails = bundle.attendees.flatMap { $0.emails }
        
        let meetingBody: [String: Any] = [
            "path": meetingPath,
            "content": markdownContent,
            "tags": ["meeting"],
            "metadata": [
                "type": "meeting",
                "title": m.title,
                "date": dateStr,
                "platform": m.platform,
                "attendees": attendeeNames,
                "attendeeEmails": attendeeEmails,
                "source": "minutes",
                "minutes_meeting_id": m.id
            ],
            // One-shot legacy export: existing meetings must fail rather than silently ignore edits.
            "if_exists": "error"
        ]
        
        guard let meetingNoteId = try await postNote(body: meetingBody, token: token) else {
            return ExportResult(adapterId: Self.id, success: false, error: "Failed to create meeting note")
        }
        
        // 3. Link Person notes with "attended-by" relationship
        if !personNoteIds.isEmpty {
            let linksAdd = personNoteIds.map { ["target": $0, "relationship": "attended-by"] }
            let patchBody: [String: Any] = [
                "links": ["add": linksAdd],
                "force": true
            ]
            try await patchNote(id: meetingNoteId, body: patchBody, token: token)
        }
        
        return ExportResult(
            adapterId: Self.id,
            externalRef: meetingNoteId,
            pathOrURL: "\(vaultHost)/vault/\(vaultName)/api/notes/\(meetingNoteId)",
            success: true
        )
    }
    
    private func postNote(body: [String: Any], token: String) async throws -> String? {
        guard let url = URL(string: "\(vaultHost)/vault/\(vaultName)/api/notes") else {throw LegacyExportError.invalidDestination}
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        req.timeoutInterval = 30
        let (data, res) = try await session.data(for: req)
        guard let httpRes = res as? HTTPURLResponse else {
            return nil
        }
        guard httpRes.statusCode == 200 || httpRes.statusCode == 201 else {throw LegacyExportError.httpStatus(httpRes.statusCode)}

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        return nil
    }
    
    private func patchNote(id: String, body: [String: Any], token: String) async throws {
        guard id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil, let url = URL(string: "\(vaultHost)/vault/\(vaultName)/api/notes/\(id)") else {throw LegacyExportError.invalidDestination}
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        req.timeoutInterval = 30
        let (_, response) = try await session.data(for:req)
        guard let http=response as? HTTPURLResponse else {throw LegacyExportError.invalidResponse}
        guard (200...299).contains(http.statusCode) else {throw LegacyExportError.httpStatus(http.statusCode)}
    }
}

private func exportIdentity(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
private func yamlString(_ value:String)->String {String(data:(try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8),encoding:.utf8) ?? "\"\""}

public enum LegacyExportError: Error, LocalizedError {
    case invalidDestination, invalidResponse, httpStatus(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDestination:return "Invalid export destination. Use HTTPS, or loopback HTTP for local development."
        case .invalidResponse:return "The legacy vault server returned an invalid response."
        case .httpStatus(let status):return "Legacy vault export failed (HTTP \(status)); no successful sync was recorded."
        }
    }
}
