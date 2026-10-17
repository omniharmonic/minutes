/// Input changes require a fresh native graph. A healthy output-only event does
/// not interrupt recording; startup's zero-frame restart keeps its own deadline.
enum CaptureRoutePolicy {
    static func shouldRebuild(engineRunning: Bool, formatMatches: Bool,
                              inputRouteMatches: Bool, hasCommittedAudio: Bool) -> Bool {
        !formatMatches || !inputRouteMatches || (!engineRunning && hasCommittedAudio)
    }
}
