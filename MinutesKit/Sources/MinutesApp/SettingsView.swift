#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesUI

@available(macOS 15.0, iOS 18.0, *)
public struct SettingsView: View {
    @ObservedObject public var appState: AppState
    @State private var savedToast: Bool = false
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(MinutesTheme.primary)
                        Text("Application Settings")
                            .font(.title2.bold())
                            .foregroundStyle(MinutesTheme.text)
                    }
                    Text("Configure local storage, knowledge vault connections, and diarization parameters.")
                        .font(.subheadline)
                        .foregroundStyle(MinutesTheme.muted)
                }
                
                // Knowledge Vault Exports
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(MinutesTheme.primary)
                        Text("KNOWLEDGE GRAPH EXPORT TARGETS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.primary)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Parachute Vault Host Endpoint:")
                                .font(.caption.bold())
                            TextField("Host URL", text: $appState.parachuteHost)
                                .textFieldStyle(.roundedBorder)
                            Text("Default is http://localhost:1940 (or 127.0.0.1:1940).")
                                .font(.caption)
                                .foregroundStyle(MinutesTheme.muted)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Obsidian Markdown Export Directory:")
                                .font(.caption.bold())
                            TextField("Path", text: $appState.markdownDirectory)
                                .textFieldStyle(.roundedBorder)
                            Text("Vault directory where Obsidian-compatible meeting markdown files will be written.")
                                .font(.caption)
                                .foregroundStyle(MinutesTheme.muted)
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Diarization Engine Defaults
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(MinutesTheme.purple)
                        Text("DIARIZATION SENSITIVITY DEFAULTS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.purple)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Default Pause Threshold:")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(String(format: "%.1f seconds", appState.diarizationConfig.pauseThreshold))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(MinutesTheme.primary)
                            }
                            Slider(value: $appState.diarizationConfig.pauseThreshold, in: 0.5...3.5, step: 0.1)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Default Aggressiveness:")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(String(format: "%.2f", appState.diarizationConfig.aggressiveness))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(MinutesTheme.purple)
                            }
                            Slider(value: $appState.diarizationConfig.aggressiveness, in: 0.0...1.0, step: 0.05)
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Action Buttons
                HStack {
                    Button("Save Configuration") {
                        savedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            savedToast = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MinutesTheme.primary)
                    
                    if savedToast {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MinutesTheme.emerald)
                            Text("Saved to preferences")
                                .font(.caption.bold())
                                .foregroundStyle(MinutesTheme.emerald)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(MinutesTheme.bg)
    }
}
#endif
