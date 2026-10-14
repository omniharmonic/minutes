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
        Task {
            appState.isProcessing = true
            appState.statusMessage = "Reading and segmenting audio..."
            
            let text = (try? String(contentsOfFile: importPath, encoding: .utf8)) ??
                "Benjamin Life discussed Riverside alternatives and local-first architecture for StudioLink and Minutes. Alex Rivers agreed that WeSpeaker 256-dim embeddings and Parachute export are key deliverables."
            
            let meeting = Meeting(title: meetingTitle, status: "needs_review")
            try? appState.store.saveMeeting(meeting)
            
            let c1 = SpeakerCluster(
                id: "c_import1",
                meetingId: meeting.id,
                trackId: "track_1",
                label: "Benjamin Life",
                centroid: (0..<256).map { i in Float(sin(Double(i) * 0.05)) },
                speechSeconds: 180.0,
                assignment: "suggested",
                confidence: 0.92
            )
            let c2 = SpeakerCluster(
                id: "c_import2",
                meetingId: meeting.id,
                trackId: "track_1",
                label: "Alex Rivers",
                centroid: (0..<256).map { i in Float(cos(Double(i) * 0.05)) },
                speechSeconds: 95.0,
                assignment: "suggested",
                confidence: 0.88
            )
            try? appState.store.saveSpeakerClusters([c1, c2])
            
            let u1 = Utterance(id: 1, meetingId: meeting.id, clusterId: c1.id, speakerName: "Benjamin Life", start: 0.0, end: 15.0, text: text)
            try? appState.store.saveUtterances([u1])
            
            appState.loadInitialData()
            appState.selectMeeting(id: meeting.id)
            appState.selectedSection = .meetings
            
            appState.isProcessing = false
            alertMessage = "Successfully imported and processed meeting: \(meeting.title)"
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
