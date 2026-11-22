#if os(macOS) && canImport(SwiftUI)
import Foundation
import Combine
import MinutesControl
import os

/// Runs the control socket while Settings > Automation (user default
/// `controlSocketEnabled`) is on. Requests hop to the main actor and run
/// against the app's AppState; see docs/CONTROL_API.md.
@MainActor
final class ControlServer {
    private weak var state: AppState?
    private var server: ControlSocketServer?
    private var subscription: AnyCancellable?
    private let path: String
    private let log = Logger(subsystem: "app.minutes", category: "control")

    init(state: AppState, path: String = ControlSocketPath.resolve()) {
        self.state = state
        self.path = path
        subscription = state.$controlSocketEnabled.removeDuplicates().sink { [weak self] enabled in
            self?.apply(enabled: enabled)
        }
    }

    private func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard server == nil, let state else { return }
        let server = ControlSocketServer(path: path) { [weak state] request in
            guard let state else { return ControlResponse(id: request.id, error: ControlError(.internal, "Minutes is shutting down")) }
            return await state.handleControlRequest(request)
        }
        do {
            try server.start()
            self.server = server
            state.controlSocketMessage = "Listening on \(path)"
        } catch {
            log.error("Control socket could not start: \(error.localizedDescription, privacy: .public)")
            state.controlSocketMessage = "Could not start: \(error.localizedDescription)"
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        state?.controlSocketMessage = "Off"
    }
}
#endif
