import Foundation
import AVFoundation
import Testing
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesCalendar
@testable import MinutesApp

/// Deterministic timed tokens replace ASR only. Real installed Fluid weights,
/// decoding, alignment, AppState identity/persistence and calendar binder run.
/// No Speech consent request, playback, capture, real calendar, or user DB access.
private struct IdentityFixtureTranscription: SpeechTranscriptionBackend {
    func transcribe(audioURL: URL, fallbackTranscriptURL: URL?) async throws -> [ASRWord] {
        let audio = try AudioDecoder.decode(fileURL: audioURL, targetSampleRate: 16000)
        return stride(from: 0.0, to: audio.duration - 0.25, by: 0.5).map {
            ASRWord(word: "Fixture", start: $0, end: min($0 + 0.4, audio.duration), confidence: 1)
        }
    }
}

@MainActor
@Suite("Opt-in integrated trained identity workflow", .serialized)
struct IntegratedTrainedIdentityAcceptanceTests {
    @Test("Calendar binding, trained app processing, explicit learning and later automatic reuse persist",
          .enabled(if: ProcessInfo.processInfo.environment["MINUTES_MODELS"] == "1"))
    func calendarThroughAppStateAndReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        let modelsURL = URL(fileURLWithPath: try #require(env["MINUTES_MODELS_DIR"])).standardizedFileURL
        let fixtures = URL(fileURLWithPath: try #require(env["MINUTES_IDENTITY_FIXTURE_DIRECTORY"])).standardizedFileURL
        guard temporary(modelsURL), temporary(fixtures) else { Issue.record("Only isolated tmp fixtures/models permitted"); return }
        let models = ModelManager(modelsDirectory: modelsURL)
        try models.validateDiarizationModels()
        let root = URL(fileURLWithPath: "/private/tmp/minutes-integrated-identity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "minutes-integrated-identity-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "summaryUsesAppleIntelligence")
        preferences.set(false, forKey: "autoFileMeetingsEnabled")
        let pipeline = PipelineOrchestrator(asrService: IdentityFixtureTranscription(),
            diarizationService: DiarizationService(backend: FluidDiarizationBackend(models: models)))
        let database = root.appendingPathComponent("isolated.sqlite").path
        let store = try MinutesStore(dbPath: database)
        let amber = Person(id: "fixture-amber", displayName: "Amber Fixture", emails: ["amber@example.test"])
        let rowan = Person(id: "fixture-rowan", displayName: "Rowan Fixture", emails: ["rowan@example.test"])
        for person in [amber, rowan] { try store.savePerson(person) }
        func event(_ id: String) -> CalendarMeetingEvent {
            CalendarMeetingEvent(eventIdentifier: id, calendarIdentifier: "fictional", title: "Generated identity fixture",
                start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600),
                attendees: CalendarParticipantMapper.map([
                    CalendarParticipant(name: "Calendar Amber", url: "mailto:AMBER@example.test", isCurrentUser: false, responseStatus: "accepted"),
                    CalendarParticipant(name: "Rowan Fixture", url: "mailto:rowan@example.test", isCurrentUser: false, responseStatus: "tentative"),
                    CalendarParticipant(name: "Declined Fixture", url: "mailto:declined@example.test", isCurrentUser: false, responseStatus: "declined"),
                    CalendarParticipant(name: "Unknown RSVP", url: "mailto:unknown@example.test", isCurrentUser: false)
                ]))
        }
        func state(_ db: MinutesStore) throws -> AppState {
            try AppState(store: db, audioDirectory: root, preferences: preferences,
                processAudio: { id, url, config in try await pipeline.process(meetingId: id, audioURL: url, config: config) })
        }
        func process(_ id: String, turns: [Int], in db: MinutesStore) async throws -> [SpeakerCluster] {
            let audio = root.appendingPathComponent(id + ".wav")
            let samples = try turns.flatMap { index in
                try AudioDecoder.decode(fileURL: fixtures.appendingPathComponent(String(format: "turn-%02d.wav", index)), targetSampleRate: 16000).samples
            }
            try writeWAV(samples, to: audio)
            try db.saveMeeting(Meeting(id: id, title: "Generated fixture", audioPath: audio.path))
            try CalendarMeetingBinder.bind(meetingId: id, event: event(id), store: db)
            let app = try state(db)
            app.selectMeeting(id: id)
            await app.processCurrentMeeting()
            #expect(db.getMeeting(id: id)?.status == "needs_review", "Processing must persist: \(app.statusMessage)")
            let clusters = db.listSpeakerClusters(meetingId: id)
            let utterances = db.listUtterances(meetingId: id)
            #expect(!clusters.isEmpty && !utterances.isEmpty)
            #expect(utterances.allSatisfy { utterance in clusters.contains { $0.id == utterance.clusterId } })
            return clusters
        }
        let enrollmentA = try await process("enroll-a", turns: [0, 2], in: store)
        let enrollmentB = try await process("enroll-b", turns: [1, 3], in: store)
        #expect((enrollmentA + enrollmentB).allSatisfy { $0.personId == nil })
        #expect(store.listVoiceprints().isEmpty)
        let learnedA = try #require(enrollmentA.max(by: { $0.speechSeconds < $1.speechSeconds }))
        let learnedB = try #require(enrollmentB.max(by: { $0.speechSeconds < $1.speechSeconds }))
        #expect(VoiceEnrollment.isEligible(learnedA) && VoiceEnrollment.isEligible(learnedB))
        try VoiceEnrollment.remember(store: store, personID: amber.id, meetingID: "enroll-a", clusterID: learnedA.id, expected: learnedA)
        try VoiceEnrollment.remember(store: store, personID: rowan.id, meetingID: "enroll-b", clusterID: learnedB.id, expected: learnedB)
        let confirmed = try #require(store.listSpeakerClusters(meetingId: "enroll-a").first { $0.id == learnedA.id })
        try VoiceEnrollment.remember(store: store, personID: amber.id, meetingID: "enroll-a", clusterID: learnedA.id, expected: confirmed)
        #expect(store.listVoiceprints().count == 2, "Repeated explicit enrollment is idempotent")
        let reopened = try MinutesStore(dbPath: database)
        #expect(reopened.listVoiceprints().count == 2)
        #expect(reopened.listVoiceprints().allSatisfy { $0.model == SpeakerEmbeddingModel.trainedID && $0.dim == 256 && $0.speechSeconds >= 20 })
        let attendees = reopened.listMeetingAttendees(meetingId: "enroll-a")
        #expect(Set(attendees.map(\.email)) == ["amber@example.test", "rowan@example.test", "unknown@example.test"])
        #expect(attendees.first { $0.personId == amber.id }?.responseStatus == "accepted")
        #expect(attendees.first { $0.personId == rowan.id }?.responseStatus == "tentative")
        #expect(attendees.first { $0.email == "unknown@example.test" }?.responseStatus == "unknown")
        #expect(reopened.getPerson(id: amber.id)?.displayName == amber.displayName)
        let mixed = try await process("later-mixed", turns: [4, 5], in: reopened)
        let usable = mixed.filter { $0.speechSeconds >= 5 }
        #expect(Set(usable.compactMap(\.personId)) == [amber.id, rowan.id])
        #expect(usable.allSatisfy { $0.assignment == "auto" })
        for cluster in usable {
            let name = cluster.personId == amber.id ? amber.displayName : rowan.displayName
            #expect(reopened.listUtterances(meetingId: "later-mixed").filter { $0.clusterId == cluster.id }.allSatisfy { $0.speakerName == name })
        }
        let boundary = try AudioDecoder.decode(fileURL: fixtures.appendingPathComponent("turn-04.wav"), targetSampleRate: 16000).duration
        let mixedUtterances = reopened.listUtterances(meetingId: "later-mixed")
        for (firstTurn, expectedName) in [(true, amber.displayName), (false, rowan.displayName)] {
            let turn = mixedUtterances.filter { (($0.start + $0.end) / 2 < boundary) == firstTurn }
            let total = turn.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let correct = turn.filter { $0.speakerName == expectedName }.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            #expect(total > 5 && correct / total >= 0.90, "Independent generated turn must receive its actual known voice name")
            let wrongName = turn.filter { $0.speakerName != expectedName && [amber.displayName, rowan.displayName].contains($0.speakerName) }.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            print("INTEGRATED_TURN_ACCURACY firstTurn=\(firstTurn) namedDurationFraction=\(correct / total) wrongKnownNameFraction=\(wrongName / total) alignedDuration=\(total)")
        }
        let finalReload = try MinutesStore(dbPath: database)
        let display = try state(finalReload)
        display.selectMeeting(id: "later-mixed")
        #expect(Set(display.currentUtterances.map(\.speakerName)).isSuperset(of: [amber.displayName, rowan.displayName]))
        #expect(finalReload.listVoiceprints().count == 2)
        let confirmation = try state(finalReload)
        confirmation.selectMeeting(id: "enroll-a")
        await confirmation.processCurrentMeeting()
        #expect(finalReload.listSpeakerClusters(meetingId: "enroll-a").first { $0.id == learnedA.id }?.assignment == "user")
        var unknown = try #require(finalReload.listSpeakerClusters(meetingId: "later-mixed").first { $0.personId == amber.id })
        unknown.personId = nil; unknown.label = "Unknown fixture"; unknown.assignment = "unknown"
        try finalReload.saveSpeakerClusters([unknown])
        display.selectMeeting(id: "later-mixed")
        await display.processCurrentMeeting()
        #expect(finalReload.listSpeakerClusters(meetingId: "later-mixed").first { $0.id == unknown.id }?.assignment == "unknown")
        for voice in finalReload.listVoiceprints() where voice.personId == rowan.id { try finalReload.deleteVoiceprint(id: voice.id) }
        let wrong = try await process("wrong-attendee-control", turns: [7], in: finalReload)
        #expect(wrong.allSatisfy { $0.personId == nil })
        for voice in finalReload.listVoiceprints() { try finalReload.deleteVoiceprint(id: voice.id) }
        let forgotten = try await process("forgotten-control", turns: [6], in: finalReload)
        #expect(forgotten.allSatisfy { $0.personId == nil })
        try VoiceEnrollment.remember(store: finalReload, personID: amber.id, meetingID: "enroll-a", clusterID: learnedA.id)
        try finalReload.deleteMeeting(id: "enroll-a")
        let deletedReload = try MinutesStore(dbPath: database)
        #expect(deletedReload.getMeeting(id: "enroll-a") == nil)
        #expect(deletedReload.listVoiceprints().count == 1)
        let afterDeletion = try await process("after-source-delete", turns: [8], in: deletedReload)
        #expect(afterDeletion.contains { $0.personId == amber.id && $0.assignment == "auto" })
        print("INTEGRATED_TRAINED_IDENTITY_ACCEPTANCE asr=deterministic-timed-fixture realASR=false physicalCapture=false enrollmentClusters=\(enrollmentA.count),\(enrollmentB.count) laterMixedClusters=\(mixed.count) laterNamedSpeakers=\(Set(usable.compactMap(\.personId)).count) thresholds=0.88,0.12 model=\(SpeakerEmbeddingModel.trainedID)")
    }
    private func temporary(_ url: URL) -> Bool { url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/") }
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        let output = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in output.update(from: pointer.baseAddress!, count: samples.count) }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }
}
