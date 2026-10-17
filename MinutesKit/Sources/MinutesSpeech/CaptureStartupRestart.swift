import Foundation

/// The bounded restart's ordered OS boundary, injectable without audio permissions.
enum CaptureStartupRestart {
    enum Stage: String, Codable, Sendable { case sessionActivation, graphRebuild, graphValidation, engineStart }
    struct Failure: Error {
        let stage: Stage
        let underlying: NSError
    }

    static func run(activateSession: () throws -> Void, rebuildGraph: () throws -> Void = {}, validateGraph: () -> Bool,
                    prepareAndStart: () throws -> Bool) throws -> Bool {
        do { try activateSession() }
        catch { throw Failure(stage: .sessionActivation, underlying: error as NSError) }
        do { try rebuildGraph() }
        catch { throw Failure(stage: .graphRebuild, underlying: error as NSError) }
        guard validateGraph() else {
            throw Failure(stage: .graphValidation, underlying: NSError(domain: "AudioCaptureService", code: 6))
        }
        do {
            guard try prepareAndStart() else { throw NSError(domain: "AudioCaptureService", code: 4) }
            return true
        } catch { throw Failure(stage: .engineStart, underlying: error as NSError) }
    }
}
