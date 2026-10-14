import Foundation
import MinutesCore

public struct MeetingExportBundle: Sendable {
    public let meeting: Meeting
    public let attendees: [Person]
    public let clusters: [SpeakerCluster]
    public let utterances: [Utterance]
    public let summary: MeetingSummary?
    
    public init(
        meeting: Meeting,
        attendees: [Person],
        clusters: [SpeakerCluster],
        utterances: [Utterance],
        summary: MeetingSummary?
    ) {
        self.meeting = meeting
        self.attendees = attendees
        self.clusters = clusters
        self.utterances = utterances
        self.summary = summary
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
        let m = bundle.meeting
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFmt.string(from: m.startedAt)
        
        let slug = m.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        
        let filename = "\(dateStr)-\(slug).md"
        let outPath = (outputDirectory as NSString).appendingPathComponent(filename)
        
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        
        // Front-matter
        var content = "---\n"
        content += "title: \"\(m.title)\"\n"
        content += "date: \(dateStr)\n"
        content += "tags: [meeting]\n"
        content += "minutes_id: \"\(m.id)\"\n"
        if !bundle.attendees.isEmpty {
            let wikilinks = bundle.attendees.map { "\"([[\($0.displayName)]])\"" }.joined(separator: ", ")
            content += "attendees: [\(wikilinks)]\n"
        }
        content += "---\n\n"
        
        if let summary = bundle.summary {
            content += summary.markdown
        } else {
            content += "# \(m.title)\n\n"
            for u in bundle.utterances {
                content += "**\(u.speakerName)**: \(u.text)\n\n"
            }
        }
        
        try content.write(toFile: outPath, atomically: true, encoding: .utf8)
        return ExportResult(adapterId: Self.id, externalRef: m.id, pathOrURL: outPath, success: true)
    }
}

// MARK: - ParachuteAdapter

public final class ParachuteAdapter: ExportAdapter {
    public static let id = "parachute"
    public let displayName = "Parachute Vault"
    public let vaultHost: String // e.g. "http://localhost:1940"
    public let vaultName: String // "default"
    public let tokenProvider: @Sendable () -> String?
    
    public init(
        vaultHost: String = "http://127.0.0.1:1940",
        vaultName: String = "default",
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.vaultHost = vaultHost
        self.vaultName = vaultName
        self.tokenProvider = tokenProvider ?? { ParachuteAdapter.mintTokenFromCLI() }
    }
    
    public static func mintTokenFromCLI() -> String? {
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
    }
    
    public func export(bundle: MeetingExportBundle) async throws -> ExportResult {
        guard let token = tokenProvider() else {
            return ExportResult(adapterId: Self.id, success: false, error: "Failed to mint or acquire Parachute token")
        }
        
        let m = bundle.meeting
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFmt.string(from: m.startedAt)
        
        let slug = m.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        
        let meetingPath = "vault/meetings/\(dateStr)/\(slug)"
        
        // 1. Ensure Person notes exist for attendees
        var personNoteIds: [String] = []
        for attendee in bundle.attendees {
            let personSlug = attendee.displayName.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            let personPath = "vault/people/\(personSlug)"
            
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
        let markdownContent = bundle.summary?.markdown ?? "# \(m.title)\n\nMeeting transcript and notes."
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
            "if_exists": "ignore"
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
        let url = URL(string: "\(vaultHost)/vault/\(vaultName)/api/notes")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, res) = try await URLSession.shared.data(for: req)
        guard let httpRes = res as? HTTPURLResponse else {
            return nil
        }
        guard httpRes.statusCode == 200 || httpRes.statusCode == 201 else {
            let errStr = String(data: data, encoding: .utf8) ?? ""
            print("Parachute note creation failed (\(httpRes.statusCode)): \(errStr)")
            return nil
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        return nil
    }
    
    private func patchNote(id: String, body: [String: Any], token: String) async throws {
        let url = URL(string: "\(vaultHost)/vault/\(vaultName)/api/notes/\(id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try? await URLSession.shared.data(for: req)
    }
}
