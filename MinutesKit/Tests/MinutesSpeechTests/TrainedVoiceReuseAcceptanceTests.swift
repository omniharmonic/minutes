import Foundation
import Testing
import MinutesCore
import MinutesSpeakerID
@testable import MinutesSpeech

/// Installed weights + generated voices only. No Apple Speech, microphone,
/// downloads, real profiles or normal application database are accessed.
@Suite("Opt-in trained voice reuse acceptance", .serialized)
struct TrainedVoiceReuseAcceptanceTests {
    @Test("Consented generated profiles persist, reload and identify independent turns conservatively",
          .enabled(if: ProcessInfo.processInfo.environment["MINUTES_MODELS"] == "1"))
    func rememberedGeneratedVoicesSurviveReload() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelRoot = URL(fileURLWithPath: try #require(environment["MINUTES_MODELS_DIR"])).standardizedFileURL
        let fixtureRoot = URL(fileURLWithPath: environment["MINUTES_IDENTITY_FIXTURE_DIRECTORY"] ?? "/private/tmp/minutes-extended-speech").standardizedFileURL
        guard temporary(modelRoot), temporary(fixtureRoot) else {
            Issue.record("This acceptance requires isolated model and generated-fixture directories under tmp")
            return
        }
        let models = ModelManager(modelsDirectory: modelRoot)
        try models.validateDiarizationModels() // Read installed weights; never setup/download.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-generated-identity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if environment["MINUTES_KEEP_GENERATED_IDENTITY_FIXTURE"] == "1" { print("GENERATED_IDENTITY_DIRECTORY " + root.path) }
            else { try? FileManager.default.removeItem(at: root) }
        }
        let service = DiarizationService(backend: FluidDiarizationBackend(models: models))
        func audio(_ turns: [Int]) throws -> [Float] {
            try turns.flatMap { index in
                try AudioDecoder.decode(fileURL: fixtureRoot.appendingPathComponent(String(format: "turn-%02d.wav", index)), targetSampleRate: 16000).samples
            }
        }
        let amberEnrollment = try await service.diarize(samples: audio([0, 2]), meetingId: "generated-enrollment-a")
        let danielEnrollment = try await service.diarize(samples: audio([1, 3]), meetingId: "generated-enrollment-b")
        // A concatenation can produce brief acoustic fragments. Explicit fictional
        // confirmation selects the dominant usable cluster; no clusters are forced
        // or merged to make the expected voice count fit.
        let learnedA = try #require(amberEnrollment.clusters.max(by: { $0.speechSeconds < $1.speechSeconds }))
        let learnedB = try #require(danielEnrollment.clusters.max(by: { $0.speechSeconds < $1.speechSeconds }))
        #expect(learnedA.speechSeconds >= 20 && learnedB.speechSeconds >= 20)
        guard learnedA.speechSeconds >= 20, learnedB.speechSeconds >= 20 else { return }
        let amber = Person(id: "fictional-amber", displayName: "Amber Fixture", emails: ["amber@example.test"])
        let daniel = Person(id: "fictional-control", displayName: "Control Fixture", emails: ["control@example.test"])
        let path = root.appendingPathComponent("isolated.sqlite").path
        // Persist explicit fictional confirmation through the same store API as UI enrollment.
        do {
            let store = try MinutesStore(dbPath: path)
            for (person, cluster) in [(amber, learnedA), (daniel, learnedB)] {
                try store.savePerson(person)
                try store.saveMeeting(Meeting(id: cluster.meetingId, title: "Generated enrollment"))
                try store.saveSpeakerClusters([cluster])
                try VoiceEnrollment.remember(store: store, personID: person.id, meetingID: cluster.meetingId,
                    clusterID: cluster.id, expected: cluster)
            }
        }
        let reloaded = try MinutesStore(dbPath: path)
        let profiles = reloaded.listVoiceprints()
        #expect(profiles.count == 2)
        let validPersistedProfiles = profiles.allSatisfy { $0.model == SpeakerEmbeddingModel.trainedID && $0.dim == 256 && $0.speechSeconds >= 20 }
        #expect(validPersistedProfiles)
        let amberProbe = try await service.diarize(samples: audio([4]), meetingId: "generated-probe-a")
        let danielProbe = try await service.diarize(samples: audio([5]), meetingId: "generated-probe-b")
        #expect(amberProbe.clusters.count == 1 && danielProbe.clusters.count == 1)
        let probeA = try #require(amberProbe.clusters.first), probeB = try #require(danielProbe.clusters.first)
        let aToA = VectorMath.cosineSimilarity(probeA.centroid, learnedA.centroid)
        let aToB = VectorMath.cosineSimilarity(probeA.centroid, learnedB.centroid)
        let bToA = VectorMath.cosineSimilarity(probeB.centroid, learnedA.centroid)
        let bToB = VectorMath.cosineSimilarity(probeB.centroid, learnedB.centroid)
        emit(["sameVoiceSimilarity": aToA, "otherVoiceSimilarity": aToB, "margin": aToA - aToB,
              "controlSameSimilarity": bToB, "controlOtherSimilarity": bToA,
              "controlMargin": bToB - bToA, "requiredSimilarity": 0.88, "requiredMargin": 0.12,
              "enrollmentSpeechSeconds": learnedA.speechSeconds, "controlEnrollmentSpeechSeconds": learnedB.speechSeconds,
              "enrollmentAcousticClusters": amberEnrollment.clusters.count, "controlEnrollmentAcousticClusters": danielEnrollment.clusters.count])
        #expect(aToA >= 0.88 && aToA - aToB >= 0.12)
        #expect(bToB >= 0.88 && bToB - bToA >= 0.12)
        let liveMatcher = LiveVoiceMatcher(backend: FluidDiarizationBackend(models: models))
        let liveA = try await liveMatcher.name(samples: Array(try audio([4]).prefix(10 * 16000)), rate: 16000,
            people: reloaded.listPeople(), voiceprints: profiles)
        let liveB = try await liveMatcher.name(samples: Array(try audio([5]).prefix(10 * 16000)), rate: 16000,
            people: reloaded.listPeople(), voiceprints: profiles)
        #expect(liveA == amber.displayName)
        #expect(liveB == daniel.displayName)
        emit(["liveWindowsNamed": [liveA, liveB].compactMap { $0 }.count])
        struct Truth: Decodable {
            struct Turn: Decodable { let voice: String; let start: Double; let end: Double }
            let turns: [Turn]
        }
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("ground-truth.json")))
        let longAudio = try AudioDecoder.decode(fileURL: fixtureRoot.appendingPathComponent("minutes-two-speaker-long.wav"), targetSampleRate: 16000).samples
        var namedWindows = 0
        for start in stride(from: 0, to: longAudio.count, by: 10 * 16000) {
            let end = min(longAudio.count, start + 10 * 16000)
            let name = try await liveMatcher.name(samples: Array(longAudio[start..<end]), rate: 16000,
                people: reloaded.listPeople(), voiceprints: profiles)
            guard let name else { continue }
            namedWindows += 1
            let voices = Set(truth.turns.filter { $0.end > Double(start) / 16000 && $0.start < Double(end) / 16000 }.map(\.voice))
            #expect(voices.count == 1, "A caption block spanning different known voices must abstain")
            let expected = voices.first == "Samantha" ? amber.displayName : daniel.displayName
            #expect(name == expected, "A named generated window must match its ground truth")
        }
        #expect(namedWindows > 0)
        emit(["longFixtureWindows": (longAudio.count + 159999) / 160000, "longFixtureNamedWindows": namedWindows])
        let probes = [probeA, probeB]
        let utterances = probes.enumerated().map { index, cluster in
            Utterance(id: index + 1, meetingId: cluster.meetingId, clusterId: cluster.id,
                speakerName: cluster.label, start: 0, end: 1, text: "Generated fixture token")
        }
        let identified = RememberedSpeakerIdentification.apply(clusters: probes, utterances: utterances,
            people: reloaded.listPeople(), voiceprints: profiles)
        #expect(identified.clusters.map(\.personId) == [amber.id, daniel.id])
        let allAutomaticallyIdentified = identified.clusters.allSatisfy { $0.assignment == "auto" }
        #expect(allAutomaticallyIdentified)
        #expect(identified.utterances.map(\.speakerName) == [amber.displayName, daniel.displayName])
        // A calendar attendee prior must not name the different generated voice.
        let negative = RememberedSpeakerIdentification.apply(clusters: [probeB], utterances: [], people: [amber],
            voiceprints: profiles.filter { $0.personId == amber.id }, attendeePersonIDs: [amber.id])
        #expect(negative.clusters.first?.personId == nil)
        for cluster in identified.clusters { try reloaded.saveMeeting(Meeting(id: cluster.meetingId, title: "Generated probe")) }
        try reloaded.saveSpeakerClusters(identified.clusters)
        try reloaded.saveUtterances(identified.utterances)
        let secondReload = try MinutesStore(dbPath: path)
        #expect(secondReload.listUtterances(meetingId: probeA.meetingId).first?.speakerName == amber.displayName)
        #expect(secondReload.listUtterances(meetingId: probeB.meetingId).first?.speakerName == daniel.displayName)
        #expect(secondReload.listVoiceprints().count == 2, "Automatic reuse never enrolls additional profiles")
        emit(["persistedProfiles": 2, "automaticallyNamedIndependentTurns": 2, "negativeControlWrongMatches": 0])
    }
    private func temporary(_ url: URL) -> Bool { url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/") }
    private func emit(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data(("TRAINED_IDENTITY_ACCEPTANCE " + text + "\n").utf8))
    }
}
