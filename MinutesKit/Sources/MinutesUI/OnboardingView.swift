#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

@available(macOS 15.0, iOS 18.0, *)
public struct OnboardingView: View {
    @ObservedObject public var permissionManager: PermissionManager
    public let onComplete: () -> Void
    
    public init(
        permissionManager: PermissionManager = .shared,
        onComplete: @escaping () -> Void = {}
    ) {
        self.permissionManager = permissionManager
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("M")
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(
                                    LinearGradient(
                                        colors: [MinutesTheme.primary, MinutesTheme.purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minutes Onboarding")
                                    .font(.title2.bold())
                                    .foregroundStyle(MinutesTheme.text)
                                Text("Local-First Meeting Intelligence & Privacy Architecture")
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.muted)
                            }
                        }
                    }
                    Spacer()
                }
                
                // Zero-Cloud Architecture Briefing
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(MinutesTheme.emerald)
                        Text("ZERO-CLOUD PRIVACY ARCHITECTURE")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.emerald)
                    }
                    
                    Text("Minutes is built from the ground up to never send your conversations or audio to third-party SaaS servers. Every stage runs entirely on your Mac:")
                        .font(.body)
                        .foregroundStyle(MinutesTheme.text)
                        .lineSpacing(3)
                    
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            architectureItem(
                                icon: "waveform",
                                title: "FluidAudio ASR Engine",
                                desc: "On-device speech recognition via Apple Neural Engine (ANE)."
                            )
                            architectureItem(
                                icon: "brain.head.profile",
                                title: "WeSpeaker Embeddings",
                                desc: "256-dimensional speaker voiceprints computed and stored locally in SQLite."
                            )
                        }
                        GridRow {
                            architectureItem(
                                icon: "externaldrive.fill",
                                title: "Local Knowledge Sync",
                                desc: "Direct zero-hop exports to local Parachute vault (localhost:1940) and Obsidian."
                            )
                            architectureItem(
                                icon: "network.slash",
                                title: "Air-Gapped Operation",
                                desc: "Full transcription and diarization capability even when completely offline."
                            )
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // macOS Permissions Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "checkmark.circle.badge.questionmark.fill")
                            .foregroundStyle(MinutesTheme.primary)
                        Text("SYSTEM PERMISSIONS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.primary)
                        Spacer()
                        Button(action: { permissionManager.checkAllPermissions() }) {
                            Label("Re-check All", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    Text("Grant macOS permissions to allow meeting recording and calendar attendee auto-mapping.")
                        .font(.subheadline)
                        .foregroundStyle(MinutesTheme.muted)
                    
                    VStack(spacing: 12) {
                        // 1. Microphone
                        permissionRow(
                            title: "Microphone Access",
                            description: "Captures your local microphone input for meeting audio recording.",
                            status: permissionManager.micStatus,
                            actionTitle: "Request Mic",
                            action: {
                                Task {
                                    _ = await permissionManager.requestMicrophoneAccess()
                                }
                            }
                        )
                        
                        // 2. CATap / System Audio
                        permissionRow(
                            title: "System Audio (CATap)",
                            description: "Captures remote attendee audio from Zoom, Google Meet, and Teams via CoreAudio process taps.",
                            status: permissionManager.systemAudioStatus,
                            actionTitle: "Verify Audio",
                            action: {
                                Task {
                                    _ = await permissionManager.requestSystemAudioAccess()
                                }
                            }
                        )
                        
                        // 3. Screen Recording
                        permissionRow(
                            title: "Screen / System Capture",
                            description: "Required by macOS for background system audio stream acquisition.",
                            status: permissionManager.screenStatus,
                            actionTitle: "Request Screen",
                            action: {
                                _ = permissionManager.requestScreenCaptureAccess()
                            }
                        )
                        
                        // 4. Calendar Access
                        permissionRow(
                            title: "Calendar (EventKit)",
                            description: "Reads meeting events to automatically map attendee names and video conference URLs.",
                            status: permissionManager.calendarStatus,
                            actionTitle: "Request Calendar",
                            action: {
                                Task {
                                    _ = await permissionManager.requestCalendarAccess()
                                }
                            }
                        )
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Completion Footer
                HStack {
                    Spacer()
                    Button(action: onComplete) {
                        HStack(spacing: 8) {
                            Text("Launch Minutes Desktop")
                                .font(.headline)
                            Image(systemName: "arrow.right")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MinutesTheme.primary)
                }
            }
            .padding(24)
        }
        .background(MinutesTheme.bg)
    }
    
    @ViewBuilder
    private func architectureItem(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(MinutesTheme.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(MinutesTheme.text)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(MinutesTheme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        status: PermissionStatus,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MinutesTheme.text)
                    statusBadge(status)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(MinutesTheme.muted)
            }
            
            Spacer()
            
            Button(action: action) {
                Text(actionTitle)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(status == .granted ? .secondary : MinutesTheme.primary)
        }
        .padding(14)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    @ViewBuilder
    private func statusBadge(_ status: PermissionStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(status.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor(status))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor(status).opacity(0.12))
        .clipShape(Capsule())
    }
    
    private func statusColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted:
            return MinutesTheme.emerald
        case .denied, .restricted:
            return Color.red
        case .notDetermined:
            return Color.orange
        }
    }
}
#endif
