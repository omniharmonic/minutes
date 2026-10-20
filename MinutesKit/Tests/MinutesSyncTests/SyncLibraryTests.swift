import Foundation
import Testing
import MinutesCore
@testable import MinutesSync

/// A stand-in for the private CloudKit database: optimistic concurrency by
/// version, like CloudKit's record change tags.
private final class FakeCloud {
    var records: [String: (payload: Data, version: Int)] = [:]
    var tombstones: [String: Int] = [:]
    var audioFiles: [String: URL] = [:]
    var clock = 0
}

/// One device's library plus its view of the cloud.
private final class Device {
    let store: MinutesStore
    let library: SyncLibrary
    let audio: URL
    var seenClock = 0
    init(seedStarters: Bool = true) throws {
        audio = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        store = try MinutesStore(dbPath: ":memory:")
        if seedStarters { try store.seedStarterFoldersIfNeeded() }
        library = SyncLibrary(store: store, audioDirectory: audio)
    }

    /// Fetch, then send until the cloud accepts every local change.
    func sync(_ cloud: FakeCloud) throws {
        for (name, value) in cloud.records.sorted(by: { order($0.key) < order($1.key) }) where value.version > seenClock {
            let record = SyncRecordName(name)!
            let ours = try library.systemFields(record).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
            if ours != value.version { try library.applyRemote(record, payload: value.payload, systemFields: Data(String(value.version).utf8), audioFile: cloud.audioFiles[name]) }
        }
        for (name, clock) in cloud.tombstones where clock > seenClock { try library.applyRemoteDeletion(SyncRecordName(name)!) }
        seenClock = cloud.clock
        for _ in 0..<3 {
            let changes = try library.pendingChanges()
            if changes.isEmpty { break }
            for change in changes {
                switch change {
                case .save(let name):
                    let known = try library.systemFields(name).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                    if let server = cloud.records[name.description], server.version != known {
                        // serverRecordChanged: merge the newer server copy, then retry.
                        try library.applyRemote(name, payload: server.payload, systemFields: Data(String(server.version).utf8))
                        continue
                    }
                    guard let payload = try library.localPayload(name) else { continue }
                    cloud.clock += 1
                    cloud.records[name.description] = (payload, cloud.clock)
                    if name.kind == .audio { cloud.audioFiles[name.description] = library.audioFile(for: name.id) }
                    try library.acknowledgeSaved(name, payload: payload, systemFields: Data(String(cloud.clock).utf8))
                case .delete(let name):
                    cloud.clock += 1
                    cloud.records[name.description] = nil
                    cloud.tombstones[name.description] = cloud.clock
                    try library.acknowledgeDeleted(name)
                }
            }
            seenClock = cloud.clock
        }
    }

    private func order(_ name: String) -> Int {
        name.hasPrefix("Folder") ? 0 : name.hasPrefix("Person") ? 1 : name.hasPrefix("Meeting") ? 2 : 3
    }
}

struct SyncLibraryTests {
    private func seedMeeting(_ device: Device, id: String = "m1") throws {
        let store = device.store
        let folder = try #require(try store.listFolders().first)
        let folderURL = device.audio.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let audio = folderURL.appendingPathComponent("mixed.m4a")
        try Data(repeating: 7, count: 2_048).write(to: audio)
        try store.saveMeeting(Meeting(id: id, title: "Planning", startedAt: Date(timeIntervalSince1970: 1_000), platform: "inperson", status: "summarized", userNotes: "Bring the budget", audioPath: audio.path))
        try store.savePerson(Person(id: "p1", displayName: "Priya", emails: ["priya@example.test"]))
        try store.replaceMeetingAttendees(meetingId: id, attendees: [MeetingAttendee(meetingId: id, personId: "p1", email: "priya@example.test", name: "Priya")])
        try store.saveUtterances([Utterance(id: 1, meetingId: id, clusterId: "c1", speakerName: "Priya", start: 3, end: 9, text: "Launch moves to May.")])
        try store.saveSpeakerClusters([SpeakerCluster(id: "c1", meetingId: id, trackId: "mic", label: "Priya", centroid: [0.1, 0.2], speechSeconds: 6, personId: "p1", assignment: "user", embeddingModel: "wespeaker")])
        try store.saveSummary(MeetingSummary(meetingId: id, title: "Planning", overview: "Launch moved", markdown: "- Launch moves to May [T0001]"))
        try store.saveBookmark(Bookmark(id: "b1", meetingId: id, timestamp: 4, label: "Launch"))
        try store.moveMeeting(id: id, toFolderID: folder.id)
    }

    @Test("A meeting made on one device arrives complete on the other, without voice embeddings")
    func meetingArrives() throws {
        let cloud = FakeCloud(), mac = try Device(), phone = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud); try phone.sync(cloud)
        let meeting = try #require(phone.store.getMeeting(id: "m1"))
        #expect(meeting.title == "Planning" && meeting.userNotes == "Bring the budget")
        #expect(phone.store.listUtterances(meetingId: "m1").first?.text == "Launch moves to May.")
        #expect(phone.store.getSummary(meetingId: "m1")?.overview == "Launch moved")
        #expect(phone.store.listBookmarks(meetingId: "m1").map(\.label) == ["Launch"])
        #expect(phone.store.listPeopleForMeeting(meetingId: "m1").map(\.displayName) == ["Priya"])
        let cluster = try #require(phone.store.listSpeakerClusters(meetingId: "m1").first)
        #expect(cluster.centroid.isEmpty && cluster.label == "Priya" && cluster.assignment == "user")
        #expect(cloud.records.values.allSatisfy { !String(decoding: $0.payload, as: UTF8.self).contains("wespeaker") })
        // Starter folders are adopted rather than duplicated, and the meeting is filed there.
        #expect(try phone.store.listFolders().count == mac.store.listFolders().count)
        #expect(try phone.store.folderMembership(meetingID: "m1")?.folderID == mac.store.folderMembership(meetingID: "m1")?.folderID)
        // Audio travels as its own record and lands in the synced folder.
        #expect(cloud.records["Audio:m1"] != nil)
        let downloaded = try #require(phone.store.getMeeting(id: "m1")?.audioPath)
        #expect(downloaded.hasSuffix("synced/m1.m4a") && FileManager.default.contentsEqual(atPath: downloaded, andPath: mac.store.getMeeting(id: "m1")!.audioPath!))
        #expect(try mac.library.pendingChanges().isEmpty && phone.library.pendingChanges().isEmpty)
    }

    @Test("Edits on both devices merge: title from one, a moment from the other, both versions of notes")
    func concurrentEditsMerge() throws {
        let cloud = FakeCloud(), mac = try Device(), phone = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud); try phone.sync(cloud)
        var onMac = try #require(mac.store.getMeeting(id: "m1"))
        onMac.title = "Launch planning"; onMac.userNotes = "Mac note"
        try mac.store.saveMeeting(onMac)
        var onPhone = try #require(phone.store.getMeeting(id: "m1"))
        onPhone.userNotes = "Phone note"
        try phone.store.saveMeeting(onPhone)
        try phone.store.saveBookmark(Bookmark(id: "b2", meetingId: "m1", timestamp: 8, label: "Budget"))
        try mac.sync(cloud); try phone.sync(cloud); try mac.sync(cloud)
        for device in [mac, phone] {
            let meeting = try #require(device.store.getMeeting(id: "m1"))
            #expect(meeting.title == "Launch planning")
            #expect(meeting.userNotes?.contains("Mac note") == true && meeting.userNotes?.contains("Phone note") == true)
            #expect(Set(device.store.listBookmarks(meetingId: "m1").map(\.id)) == ["b1", "b2"])
            #expect(try device.library.pendingChanges().isEmpty)
        }
    }

    @Test("Local voice embeddings survive a cluster arriving from the cloud")
    func centroidsStayLocal() throws {
        let cloud = FakeCloud(), mac = try Device(), phone = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud); try phone.sync(cloud)
        var cluster = try #require(phone.store.listSpeakerClusters(meetingId: "m1").first)
        cluster.label = "Priya Shah"
        try phone.store.saveSpeakerClusters([cluster])
        try phone.sync(cloud); try mac.sync(cloud)
        let local = try #require(mac.store.listSpeakerClusters(meetingId: "m1").first)
        #expect(local.label == "Priya Shah" && local.centroid == [0.1, 0.2] && local.embeddingModel == "wespeaker")
    }

    @Test("Trash travels; a permanent delete elsewhere moves the meeting to Recently Deleted here")
    func deletions() throws {
        let cloud = FakeCloud(), mac = try Device(), phone = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud); try phone.sync(cloud)
        try mac.store.trashMeeting(id: "m1")
        try mac.sync(cloud); try phone.sync(cloud)
        #expect(try phone.store.isMeetingInTrash(id: "m1"))
        try phone.store.restoreMeeting(id: "m1")
        try phone.sync(cloud); try mac.sync(cloud)
        #expect(try !mac.store.isMeetingInTrash(id: "m1"))
        try mac.store.deleteMeeting(id: "m1")
        try mac.sync(cloud); try phone.sync(cloud)
        #expect(cloud.records["Meeting:m1"] == nil)
        #expect(try phone.store.isMeetingInTrash(id: "m1"))
    }

    @Test("Recordings settle after one exchange and a purge does not bounce back")
    func recordingsSettle() throws {
        let cloud = FakeCloud(), mac = try Device(), phone = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud); try phone.sync(cloud); try mac.sync(cloud); try phone.sync(cloud)
        let versions = cloud.records.mapValues(\.version)
        try mac.sync(cloud); try phone.sync(cloud)
        #expect(cloud.records.mapValues(\.version) == versions, "\(cloud.records.mapValues(\.version).filter { versions[$0.key] != $0.value }.keys.sorted())")
        try mac.store.deleteMeeting(id: "m1")
        try mac.sync(cloud); try phone.sync(cloud); try mac.sync(cloud); try phone.sync(cloud)
        #expect(cloud.records["Meeting:m1"] == nil && cloud.records["Audio:m1"] == nil)
        #expect(try mac.library.pendingChanges().isEmpty && phone.library.pendingChanges().isEmpty)
    }

    @Test("A recording that arrives before recordings are turned on is fetched again later")
    func recordingWaitsForPermission() throws {
        let cloud = FakeCloud(), mac = try Device()
        try seedMeeting(mac)
        try mac.sync(cloud)
        let phoneStore = try MinutesStore(dbPath: ":memory:")
        let off = SyncLibrary(store: phoneStore, audioDirectory: nil)
        for (name, value) in cloud.records { try off.applyRemote(SyncRecordName(name)!, payload: value.payload, systemFields: nil, audioFile: cloud.audioFiles[name]) }
        #expect(phoneStore.getMeeting(id: "m1")?.audioPath == nil)
        #expect(try phoneStore.syncRecordState("Audio:m1") == nil)
    }

    @Test("Recordings in progress stay on the device until they finish")
    func inProgressStaysLocal() throws {
        let cloud = FakeCloud(), mac = try Device()
        try mac.store.saveMeeting(Meeting(id: "live", title: "Live", status: "recording"))
        try mac.sync(cloud)
        #expect(cloud.records["Meeting:live"] == nil)
    }

    @Test("Scanning for changes is safe while another thread writes (regression: unlocked trash read crashed)")
    func concurrentScan() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-sync-race-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MinutesStore(dbPath: path)
        for index in 0..<40 { try store.saveMeeting(Meeting(id: "m\(index)", title: "Meeting \(index)", status: "summarized")) }
        let library = SyncLibrary(store: store)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<25 {
                if worker % 2 == 0 { _ = try? library.pendingChanges() }
                else {
                    let id = "m\((worker * 7 + round) % 40)"
                    try? store.trashMeeting(id: id); try? store.restoreMeeting(id: id)
                    try? store.saveBookmark(Bookmark(meetingId: id, timestamp: Double(round), label: "Race"))
                }
            }
        }
        #expect(try library.pendingChanges().count == 40)
    }

    @Test("Record names round-trip and reject unknown kinds")
    func recordNames() {
        #expect(SyncRecordName("Meeting:abc")?.kind == .meeting)
        #expect(SyncRecordName("Meeting:abc")?.description == "Meeting:abc")
        #expect(SyncRecordName("Voiceprint:abc") == nil && SyncRecordName("Meeting:") == nil)
    }
}
