#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

@available(macOS 15.0, iOS 18.0, *)
public struct TranscriptView: View {
    public let utterances: [Utterance]
    public let onSeek: (Double) -> Void
    
    public init(utterances: [Utterance], onSeek: @escaping (Double) -> Void = { _ in }) {
        self.utterances = utterances
        self.onSeek = onSeek
    }
    
    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(utterances) { u in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(u.speakerName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(speakerColor(u.speakerName))
                            
                            Button(action: { onSeek(u.start) }) {
                                Text(formatTime(u.start))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Text(u.text)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }
    
    private func formatTime(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", mins, s)
    }
    
    private func speakerColor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .orange]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}

@available(macOS 15.0, iOS 18.0, *)
public struct SummaryView: View {
    public let summary: MeetingSummary
    public let onExportParachute: () -> Void
    public let onExportMarkdown: () -> Void
    
    public init(
        summary: MeetingSummary,
        onExportParachute: @escaping () -> Void,
        onExportMarkdown: @escaping () -> Void
    ) {
        self.summary = summary
        self.onExportParachute = onExportParachute
        self.onExportMarkdown = onExportMarkdown
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Actions
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .font(.title2.bold())
                        Text("Generated On-Device · FluidAudio Parakeet Ultra")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Export to Parachute", action: onExportParachute)
                        .buttonStyle(.borderedProminent)
                    Button("Export Markdown", action: onExportMarkdown)
                        .buttonStyle(.bordered)
                }
                
                // Overview
                VStack(alignment: .leading, spacing: 6) {
                    Text("OVERVIEW")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(summary.overview)
                        .font(.body)
                        .padding()
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                // Decisions
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("KEY DECISIONS")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(summary.decisions, id: \.self) { d in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.subheadline)
                                Text(d)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                
                // Action items
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACTION ITEMS")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(summary.actionItems, id: \.text) { a in
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                Text(a.text)
                                    .font(.subheadline)
                                if let owner = a.owner {
                                    Text("@\(owner)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
#endif
