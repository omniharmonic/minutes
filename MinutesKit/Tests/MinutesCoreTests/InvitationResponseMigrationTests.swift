import Foundation
import SQLite3
import Testing
import MinutesCore

struct InvitationResponseMigrationTests {
    @Test("Pre-RSVP stores retain invitees, accept response updates and reopen idempotently")
    func legacyInviteesSurviveMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-invitation-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let setup = """
        CREATE TABLE meeting_attendee (
            meeting_id TEXT NOT NULL, person_id TEXT, email TEXT NOT NULL,
            name TEXT, is_organizer INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(meeting_id, email));
        INSERT INTO meeting_attendee VALUES ('legacy', NULL, 'casey@example.test', 'Casey Fixture', 1);
        """
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = try MinutesStore(dbPath: path)
            let invitee = try #require(store.listMeetingAttendees(meetingId: "legacy").first)
            #expect(invitee.name == "Casey Fixture" && invitee.isOrganizer)
            #expect(invitee.responseStatus == "unknown")
            try store.saveMeetingAttendees([MeetingAttendee(meetingId: "legacy", email: invitee.email,
                name: invitee.name, isOrganizer: true, responseStatus: "accepted")])
        }
        let reopened = try MinutesStore(dbPath: path)
        #expect(reopened.listMeetingAttendees(meetingId: "legacy").count == 1)
        #expect(reopened.listMeetingAttendees(meetingId: "legacy").first?.responseStatus == "accepted")
    }

    @Test("Historical attendee JSON remains readable with an unknown RSVP")
    func historicalPayloadCompatibility() throws {
        let data = Data(#"{"meetingId":"legacy","email":"casey@example.test","isOrganizer":false}"#.utf8)
        let invitee = try JSONDecoder().decode(MeetingAttendee.self, from: data)
        #expect(invitee.email == "casey@example.test")
        #expect(invitee.responseStatus == "unknown")
    }
}
