#if canImport(AppKit) && canImport(Sparkle)
import Foundation
import Sparkle

/// Mac app updates from the signed appcast in the public releases repository.
/// Sparkle asks the person on second launch before checking automatically, and
/// verifies every download against `SUPublicEDKey` before installing it.
@MainActor final class AppUpdater: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
#endif
