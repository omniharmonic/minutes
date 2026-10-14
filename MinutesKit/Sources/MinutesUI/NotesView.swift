#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSummarize
import MinutesSpeech

@available(macOS 15.0, iOS 18.0, *)
public struct NotesView: View {
    public let meeting: Meeting
    @State private var notesText: String
    @State private var bookmarks: [Bookmark] = []
    @State private var newBookmarkLabel: String = ""
    public let summary: MeetingSummary?
    public let utterances: [Utterance]
    public let attendees: [Person]
    
    public let onSaveNotes: (String) -> Void
    public let onSaveBookmark: (Bookmark) -> Void
    public let onDeleteBookmark: (String) -> Void
    public let onGenerateSummary: () -> Void
    public let onExportMarkdown: () -> Void
    public let onExportParachute: () -> Void
    
    @ObservedObject private var playback = AudioPlaybackService.shared
    
    public init(
        meeting: Meeting,
        summary: MeetingSummary?,
        utterances: [Utterance],
        attendees: [Person],
        bookmarks: [Bookmark] = [],
        onSaveNotes: @escaping (String) -> Void,
        onSaveBookmark: @escaping (Bookmark) -> Void,
        onDeleteBookmark: @escaping (String) -> Void,
        onGenerateSummary: @escaping () -> Void,
        onExportMarkdown: @escaping () -> Void,
        onExportParachute: @escaping () -> Void
    ) {
        self.meeting = meeting
        self._notesText = State(initialValue: meeting.userNotes ?? "")
        self._bookmarks = State(initialValue: bookmarks)
        self.summary = summary
        self.utterances = utterances
        self.attendees = attendees
        self.onSaveNotes = onSaveNotes
        self.onSaveBookmark = onSaveBookmark
        self.onDeleteBookmark = onDeleteBookmark
        self.onGenerateSummary = onGenerateSummary
        self.onExportMarkdown = onExportMarkdown
        self.onExportParachute = onExportParachute
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left Column: User Notes & Bookmarks
            VStack(alignment: .leading, spacing: 18) {
                // Notes Header
                HStack {
                    Image(systemName: "note.text")
                        .foregroundStyle(MinutesTheme.primary)
                    Text("MEETING NOTES")
                        .font(.caption.bold())
                        .foregroundStyle(MinutesTheme.muted)
                    Spacer()
                    Text("Auto-saved to device")
                        .font(.caption2)
                        .foregroundStyle(MinutesTheme.emerald)
                }
                
                // Notes Editor
                TextEditor(text: $notesText)
                    .font(.body)
                    .foregroundStyle(MinutesTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(MinutesTheme.cardHover)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MinutesTheme.border, lineWidth: 1))
                    .frame(minHeight: 220)
                    .onChange(of: notesText) { _, newValue in
                        onSaveNotes(newValue)
                    }
                
                Divider().overlay(MinutesTheme.border)
                
                // Bookmarks Strip
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(MinutesTheme.purple)
                        Text("MOMENT BOOKMARKS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.muted)
                        Spacer()
                        Text("\(bookmarks.count) Bookmarks")
                            .font(.caption2)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    // Add Bookmark Row
                    HStack(spacing: 8) {
                        TextField("Bookmark label at current playback...", text: $newBookmarkLabel)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MinutesTheme.cardHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MinutesTheme.border, lineWidth: 1))
                        
                        Button(action: addCurrentBookmark) {
                            Label("Add (\(formatTime(playback.currentTime)))", systemImage: "plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MinutesTheme.primary)
                    }
                    
                    // Bookmarks List
                    if bookmarks.isEmpty {
                        Text("No bookmarks added yet. Tap Add above or during recording to mark key moments.")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(bookmarks) { b in
                            HStack(spacing: 10) {
                                Button(action: {
                                    playback.seek(to: b.timestamp)
                                    playback.play(from: b.timestamp, to: nil)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.caption)
                                        Text(formatTime(b.timestamp))
                                            .font(.caption.monospacedDigit().bold())
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(MinutesTheme.purple.opacity(0.15))
                                    .foregroundStyle(MinutesTheme.purple)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                
                                Text(b.label)
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.text)
                                
                                Spacer()
                                
                                Button(action: {
                                    onDeleteBookmark(b.id)
                                    bookmarks.removeAll { $0.id == b.id }
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundStyle(MinutesTheme.muted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(MinutesTheme.cardHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(18)
            .minutesCard()
            .frame(maxWidth: .infinity)
            
            // Right Column: Grounded AI Summary & Action Items
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(MinutesTheme.emerald)
                    Text("GROUNDED AI SUMMARY")
                        .font(.caption.bold())
                        .foregroundStyle(MinutesTheme.emerald)
                    Spacer()
                    
                    Button(action: onGenerateSummary) {
                        Label(summary == nil ? "Generate Summary" : "Regenerate", systemImage: "arrow.clockwise")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
                
                if let sum = summary {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Overview
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Overview")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(MinutesTheme.text)
                                Text(sum.overview)
                                    .font(.body)
                                    .foregroundStyle(MinutesTheme.muted)
                                    .lineSpacing(4)
                            }
                            
                            // Key Decisions
                            if !sum.decisions.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Key Decisions")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(MinutesTheme.text)
                                    ForEach(sum.decisions, id: \.self) { dec in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("✓")
                                                .font(.caption.bold())
                                                .foregroundStyle(MinutesTheme.emerald)
                                            Text(dec)
                                                .font(.subheadline)
                                                .foregroundStyle(MinutesTheme.text)
                                        }
                                    }
                                }
                            }
                            
                            // Action Items
                            if !sum.actionItems.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Action Items")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(MinutesTheme.text)
                                    ForEach(sum.actionItems, id: \.text) { act in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "circle")
                                                .font(.caption)
                                                .foregroundStyle(MinutesTheme.primary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(act.text)
                                                    .font(.subheadline)
                                                    .foregroundStyle(MinutesTheme.text)
                                                if let owner = act.owner {
                                                    Text("Owner: \(owner)")
                                                        .font(.caption2)
                                                        .foregroundStyle(MinutesTheme.muted)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Discussion Topics
                            if !sum.topics.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Topics Discussed")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(MinutesTheme.text)
                                    ForEach(sum.topics, id: \.title) { top in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(top.title)
                                                .font(.caption.bold())
                                                .foregroundStyle(MinutesTheme.primary)
                                            Text(top.discussion)
                                                .font(.caption)
                                                .foregroundStyle(MinutesTheme.muted)
                                        }
                                        .padding(8)
                                        .background(MinutesTheme.cardHover)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            
                            // Export Actions
                            HStack(spacing: 10) {
                                Button(action: onExportMarkdown) {
                                    Label("Export Markdown", systemImage: "doc.text")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                
                                Button(action: onExportParachute) {
                                    Label("Sync to Prism Vault", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(MinutesTheme.primary)
                            }
                            .padding(.top, 8)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32))
                            .foregroundStyle(MinutesTheme.muted)
                        Text("No grounded summary generated yet.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                        Text("Extract overview, action items, and key decisions grounded in spoken utterances.")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                            .multilineTextAlignment(.center)
                        Button("Generate Summary Now", action: onGenerateSummary)
                            .buttonStyle(.borderedProminent)
                            .tint(MinutesTheme.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(18)
            .minutesCard()
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(MinutesTheme.bg)
    }
    
    private func addCurrentBookmark() {
        let label = newBookmarkLabel.trimmingCharacters(in: .whitespaces).isEmpty ? "Key moment" : newBookmarkLabel
        let b = Bookmark(meetingId: meeting.id, timestamp: playback.currentTime, label: label)
        onSaveBookmark(b)
        bookmarks.append(b)
        newBookmarkLabel = ""
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
#endif
