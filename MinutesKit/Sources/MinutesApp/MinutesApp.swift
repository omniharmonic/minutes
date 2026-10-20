#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import MinutesUI

@MainActor
public final class AppStartup: ObservableObject {
    @Published public private(set) var state: AppState?
    @Published public private(set) var errorMessage: String?
    private let databasePath: String?
    private let libraryDirectory: URL?

    public init(databasePath: String? = nil, libraryDirectory: URL? = nil) {
        self.databasePath = databasePath
        self.libraryDirectory = libraryDirectory ?? ProcessInfo.processInfo.environment["MINUTES_LIBRARY_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        retry()
    }

    public func retry() {
        do {
            if let libraryDirectory {
                try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
                guard let preferences = UserDefaults(suiteName: "app.minutes.library.\(libraryDirectory.path)") else { throw CocoaError(.fileWriteUnknown) }
                if preferences.string(forKey: "markdownDirectory") == nil {
                    preferences.set(libraryDirectory.appendingPathComponent("exports", isDirectory: true).path, forKey: "markdownDirectory")
                }
                state = try AppState(databasePath: databasePath ?? libraryDirectory.appendingPathComponent("minutes.sqlite").path,
                    audioDirectory: libraryDirectory.appendingPathComponent("audio", isDirectory: true), preferences: preferences,
                    defaultCaptureMode: .systemAndMicrophone)
            } else {
                // Online meetings need the other participants' audio; mic-only is opt-in.
                state = try AppState(databasePath: databasePath, defaultCaptureMode: .systemAndMicrophone)
            }
            errorMessage = nil
        } catch {
            state = nil
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class MinutesApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState? {
        didSet { importPendingFile() }
    }
    private var pendingFile: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return }
        pendingFile = url
        importPendingFile()
    }

    private func importPendingFile() {
        guard let state, let url = pendingFile else { return }
        pendingFile = nil
        // Use the same copy-before-processing path as the file picker. Finder's
        // Open With never edits the supplied recording or starts capture/playback.
        Task {
            do { _ = try await state.importMedia(from: url, isTranscript: ["txt", "md"].contains(url.pathExtension.lowercased())) }
            catch { state.statusMessage = "Could not import file: \(error.localizedDescription)" }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.isRecording || state.isStartingRecording || state.isFinalizingRecording || state.isProcessing || state.isSummarizing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Finish your meeting before quitting"
        alert.informativeText = "Stop the recording and let processing finish before quitting Minutes. Your current work is still active."
        alert.addButton(withTitle: "Keep Minutes Open")
        alert.runModal()
        return .terminateCancel
    }
}

@available(macOS 15.0, *)
@main
public struct MinutesApp: App {
    @StateObject private var startup = AppStartup()
    @NSApplicationDelegateAdaptor(MinutesApplicationDelegate.self) private var applicationDelegate
    
    public init() {}
    
    public var body: some Scene {
        // Main Desktop Window
        WindowGroup("Minutes", id: "main") {
            Group {
                if let appState = startup.state {
                    MainWindowView(appState: appState)
                        .onAppear { applicationDelegate.state = appState }
                        .task { await appState.restoreCalendarConnections() }
                        .task { await appState.restorePrismConnection() }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appState.syncLibraryNow() }
                } else {
                    VStack(spacing: 16) {
                        Text("Minutes could not open your library").font(.headline)
                        Text(startup.errorMessage ?? "Storage unavailable").textSelection(.enabled)
                        Button("Retry opening library") { startup.retry() }
                    }.padding(32)
                }
            }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1292, height: 864)
        .commands {
            CommandMenu("Captions") {
                Button("Focus Caption History") { startup.state?.captionPanel.focus() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Preview Captions from Audio File…") {
                    let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                    picker.message = "Read an audio file silently into local live captions. No recording or playback."
                    if picker.runModal() == .OK, let url = picker.url { startup.state?.captionPanel.previewFile(url) }
                }.disabled(startup.state?.isRecording == true)
                Button("Show Live Captions") { if let state = startup.state { state.captionPanel.show(recording: state.isRecording) } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Preview Captions Silently") { startup.state?.captionPanel.preview() }
                    .disabled(startup.state?.isRecording == true)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Transcript") { NotificationCenter.default.post(name: Notification.Name("MinutesFindInTranscript"), object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(startup.state?.currentMeeting == nil)
                Button("Search Meetings") { NotificationCenter.default.post(name: Notification.Name("MinutesFocusLibrarySearch"), object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            CommandGroup(after: .newItem) {
                Button("New Recording") { startup.state?.selectedSection = .liveIngestion }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(startup.state == nil)
                Button("Mark Moment") { startup.state?.markRecordingMoment() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(startup.state?.isRecording != true)
                Button("Import Audio or Transcript…") { NotificationCenter.default.post(name: Notification.Name("MinutesImportAudio"), object: nil) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(startup.state == nil)
            }
        }
        
        Settings {
            if let state = startup.state { SettingsView(appState: state).frame(width: 640, height: 510).toggleStyle(MinutesToggleStyle()).tint(.yellow) }
        }

        // Menu Bar Extra Status Item
        MenuBarExtra("Minutes", systemImage: startup.state?.isRecording == true ? "record.circle.fill" : "waveform.circle") {
            if let appState = startup.state {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Minutes")
                        .font(.headline)
                    Spacer()
                    Text("v1.0 (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                if appState.isRecording {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("Recording (\(Int(appState.recordingDuration))s)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                    Button("Mark Moment (\(appState.recordingBookmarks.count))") { appState.markRecordingMoment() }
                    Button("Stop & Process Meeting") {
                        Task {
                            await appState.stopAndProcessMeeting()
                        }
                    }
                } else {
                    Button("Start Quick Meeting") {
                        Task { if await appState.prepareRecording() { appState.startQuickMeeting() } }
                    }
                }
                
                Divider()
                
                Button("Show Live Captions") { appState.captionPanel.show(recording: appState.isRecording) }
                Button("Open Minutes Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                
                Button("Save Meeting to Parachute Vault") {
                    Task {
                        _ = await appState.exportCurrentMeeting(target: "parachute")
                    }
                }
                
                Button("Export Last Meeting to Markdown") {
                    Task {
                        _ = await appState.exportCurrentMeeting(target: "markdown")
                    }
                }
                
                Divider()
                
                Button("Quit Minutes") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(4)
            } else {
                Text("Library unavailable")
                Button("Retry opening library") { startup.retry() }
                Button("Quit Minutes") { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
#endif
