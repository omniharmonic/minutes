#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

@available(macOS 15.0, *)
@main
public struct MinutesApp: App {
    @StateObject private var appState = AppState()
    
    public init() {}
    
    public var body: some Scene {
        // Main Desktop Window
        WindowGroup("Minutes", id: "main") {
            MainWindowView(appState: appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 740)
        
        // Menu Bar Extra Status Item
        MenuBarExtra("Minutes", systemImage: appState.isRecording ? "record.circle.fill" : "waveform.circle") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Minutes Meeting Intelligence")
                        .font(.headline)
                    Spacer()
                    Text("v1.0")
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
                    Button("Stop & Process Meeting") {
                        Task {
                            await appState.stopAndProcessMeeting()
                        }
                    }
                } else {
                    Button("Start Quick Meeting") {
                        appState.startQuickMeeting()
                    }
                }
                
                Divider()
                
                Button("Open Minutes Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                
                Button("Export Last Meeting to Parachute") {
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
        }
    }
}
#endif
