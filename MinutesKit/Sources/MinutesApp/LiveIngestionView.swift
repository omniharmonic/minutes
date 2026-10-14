#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesUI

@available(macOS 15.0, iOS 18.0, *)
public struct LiveIngestionView: View {
    @ObservedObject public var appState: AppState
    @State private var importPath: String = "/Users/benjaminlife/dev/no_Saas/handy-1791911766.txt"
    @State private var meetingTitle: String = "Design & Scope Review"
    @State private var showingImportAlert: Bool = false
    @State private var alertMessage: String = ""
    
    public init(appState: AppState) {
        self.permissionManager = appState.permissionManager
        self.appState = appState
    }
    
    private let permissionManager: PermissionManager
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.title2)
                            .foregroundStyle(MinutesTheme.primary)
                        Text("Live Ingestion & Processing")
                            .font(.title2.bold())
                            .foregroundStyle(MinutesTheme.text)
                    }
                    Text("Stream system audio or import recordings to run on-device ASR and speaker diarization.")
                        .font(.subheadline)
                        .foregroundStyle(MinutesTheme.muted)
                }
                
                // Live Recorder Card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(appState.isRecording ? Color.red : MinutesTheme.emerald)
                        Text(appState.isRecording ? "RECORDING ACTIVE" : "MICROPHONE & CATAP RECORDER")
                            .font(.caption.bold())
                            .foregroundStyle(appState.isRecording ? Color.red : MinutesTheme.emerald)
                        Spacer()
                        if appState.isRecording {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                    
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatDuration(appState.recordingDuration))
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .foregroundStyle(appState.isRecording ? Color.red : MinutesTheme.text)
                            Text(appState.statusMessage)
                                .font(.caption)
                                .foregroundStyle(MinutesTheme.muted)
                        }
                        
                        Spacer()
                        
                        // Animated waveform simulation bars
                        HStack(spacing: 4) {
                            ForEach(0..<12, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(appState.isRecording ? MinutesTheme.primary : MinutesTheme.border)
                                    .frame(width: 4, height: appState.isRecording ? CGFloat.random(in: 12...48) : 8)
                                    .animation(.easeInOut(duration: 0.2), value: appState.recordingDuration)
                            }
                        }
                        .frame(height: 50)
                        .padding(.horizontal, 16)
                    }
                    
                    HStack(spacing: 12) {
                        if !appState.isRecording {
                            Button(action: { appState.startQuickMeeting() }) {
                                Label("Start Recording Meeting", systemImage: "record.circle.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.red)
                        } else {
                            Button(action: {
                                Task {
                                    await appState.stopAndProcessMeeting()
                                }
                            }) {
                                Label("Stop & Ingest Audio", systemImage: "stop.circle.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MinutesTheme.primary)
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Audio & Transcript File Ingestion
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundStyle(MinutesTheme.purple)
                        Text("IMPORT AUDIO OR TRANSCRIPT FILE")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.purple)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Meeting Title:")
                                .font(.caption.bold())
                            TextField("Meeting Title", text: $meetingTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("File Path (Audio .wav / .m4a or Text .txt):")
                                .font(.caption.bold())
                            TextField("File Path", text: $importPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: importFile) {
                            HStack(spacing: 6) {
                                if appState.isProcessing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text("Process & Diarize Audio")
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MinutesTheme.primary)
                        .disabled(appState.isProcessing)
                    }
                }
                .padding(20)
                .minutesCard()
            }
            .padding(24)
        }
        .background(MinutesTheme.bg)
        .alert("Import Status", isPresented: $showingImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func importFile() {
        guard !importPath.isEmpty else {
            alertMessage = "Please enter an audio file path."
            showingImportAlert = true
            return
        }
        guard FileManager.default.fileExists(atPath: importPath) else {
            alertMessage = "File not found at path: \(importPath)"
            showingImportAlert = true
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: importPath)
        guard let fileSize = attrs?[.size] as? UInt64, fileSize > 0 else {
            alertMessage = "File is empty: \(importPath)"
            showingImportAlert = true
            return
        }
        
        Task {
            appState.isProcessing = true
            appState.statusMessage = "Importing media file..."
            
            let filename = (importPath as NSString).lastPathComponent
            let isText = filename.hasSuffix(".txt") || filename.hasSuffix(".md")
            
            if isText {
                guard let text = try? String(contentsOfFile: importPath, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    appState.isProcessing = false
                    alertMessage = "Failed to read text transcript from \(importPath)"
                    showingImportAlert = true
                    return
                }
                
                let meeting = Meeting(title: meetingTitle.isEmpty ? filename : meetingTitle, status: "needs_review")
                try? appState.store.saveMeeting(meeting)
                
                let c1 = SpeakerCluster(
                    id: "c_\(meeting.id)_1",
                    meetingId: meeting.id,
                    trackId: "track_1",
                    label: "Speaker 1",
                    centroid: [],
                    speechSeconds: 10.0,
                    assignment: "suggested",
                    confidence: 0.0
                )
                try? appState.store.saveSpeakerClusters([c1])
                
                let u1 = Utterance(id: 1, meetingId: meeting.id, clusterId: c1.id, speakerName: "Speaker 1", start: 0.0, end: 10.0, text: text)
                try? appState.store.saveUtterances([u1])
                
                appState.loadInitialData()
                appState.selectMeeting(id: meeting.id)
                appState.selectedSection = .meetings
            } else {
                // Audio file import
                let meeting = Meeting(title: meetingTitle.isEmpty ? filename : meetingTitle, status: "recorded")
                try? appState.store.saveMeeting(meeting)
                
                appState.loadInitialData()
                appState.selectMeeting(id: meeting.id)
                appState.selectedSection = .meetings
            }
            
            appState.isProcessing = false
            appState.statusMessage = "Import completed."
            alertMessage = "Imported successfully."
            showingImportAlert = true
        }
    }
    
    private func formatDuration(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", mins, s)
    }
}
#endif
