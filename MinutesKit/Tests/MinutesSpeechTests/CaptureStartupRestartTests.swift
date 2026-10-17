import Foundation
import Testing
@testable import MinutesSpeech

struct CaptureStartupRestartTests {
    @Test("Restart activates session and revalidates graph before engine prepare/start")
    func orderedRestartBoundary() throws {
        var calls: [String] = []
        let succeeded = try CaptureStartupRestart.run(activateSession: { calls.append("activate") },
            validateGraph: { calls.append("validate"); return true },
            prepareAndStart: { calls.append("start"); return true })
        #expect(succeeded)
        #expect(calls == ["activate", "validate", "start"])
    }

    @Test("Activation and graph failures prevent engine work; engine errors retain domain/code and stage")
    func stagedErrors() throws {
        let expected = NSError(domain: "FixtureAudioSession", code: 561_017_449,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE ERROR DESCRIPTION"])
        for stage in [CaptureStartupRestart.Stage.sessionActivation, .graphValidation, .engineStart] {
            var started = false
            do {
                _ = try CaptureStartupRestart.run(activateSession: { if stage == .sessionActivation { throw expected } },
                    validateGraph: { stage != .graphValidation },
                    prepareAndStart: { started = true; throw expected })
                Issue.record("Expected staged restart failure")
            } catch let error as CaptureStartupRestart.Failure {
                #expect(error.stage == stage)
                #expect(started == (stage == .engineStart))
                if stage != .graphValidation {
                    #expect(error.underlying.domain == expected.domain)
                    #expect(error.underlying.code == expected.code)
                }
            } catch { Issue.record("Restart error lost its stage") }
        }
    }
    @Test("Rebuild activation precedes fresh graph and tap creation; stale graph is never started")
    func freshGraphBoundary() throws {
        var graph = "stale"
        var starts: [String] = []
        var calls: [String] = []
        let result = try CaptureStartupRestart.run(activateSession: { calls.append("activate") },
            rebuildGraph: { graph = "fresh"; calls += ["freshGraph", "nativeTap", "newConverter"] },
            validateGraph: { calls.append("validate"); return graph == "fresh" },
            prepareAndStart: { starts.append(graph); return true })
        #expect(result)
        #expect(starts == ["fresh"])
        #expect(calls == ["activate", "freshGraph", "nativeTap", "newConverter", "validate"])
    }

}
