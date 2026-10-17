#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSummarize
import MinutesSpeech

@available(macOS 15.0, iOS 18.0, *)
public struct NotesView: View {
    public let meeting: Meeting
    @State private var notesText: String
    private let bookmarks: [Bookmark]
    @State private var newBookmarkLabel: String = ""
    @State private var summaryDraft: String = ""
    @State private var showingSummaryEditor = false
    @State private var showingBookmarks = false
    @State private var showingTranscript = false
    @State private var transcriptPlaybackError: String?
    public let onSaveSummary: ((String) -> Void)?
    public let playbackAllowed: Bool
    public let isSummarizing: Bool
    public let usesAppleIntelligence: Bool
    public let onEnableAppleSummary: (() -> Void)?
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
        onExportParachute: @escaping () -> Void,
        onSaveSummary: ((String) -> Void)? = nil,
        isSummarizing: Bool = false,
        playbackAllowed: Bool = true,
        usesAppleIntelligence: Bool = false,
        onEnableAppleSummary: (() -> Void)? = nil
    ) {
        self.meeting = meeting
        self._notesText = State(initialValue: meeting.userNotes ?? "")
        self.bookmarks = bookmarks
        self.summary = summary
        self.utterances = utterances
        self.attendees = attendees
        self.onSaveNotes = onSaveNotes
        self.onSaveBookmark = onSaveBookmark
        self.onDeleteBookmark = onDeleteBookmark
        self.onGenerateSummary = onGenerateSummary
        self.onExportMarkdown = onExportMarkdown
        self.onExportParachute = onExportParachute
        self.onSaveSummary = onSaveSummary
        self.playbackAllowed = playbackAllowed
        self.isSummarizing = isSummarizing
        self.usesAppleIntelligence = usesAppleIntelligence
        self.onEnableAppleSummary = onEnableAppleSummary
        self._summaryDraft = State(initialValue: summary?.markdown ?? "")
    }
    
    // The document already shows title/date; keep export metadata in the saved Markdown.
    private func summaryBody(_ summary: MeetingSummary) -> String {
        var lines = summary.markdown.components(separatedBy: "\n")
        guard lines.first == "# \(summary.title)" else { return summary.markdown }
        lines.removeFirst()
        while let first = lines.first,
              first.isEmpty || first.hasPrefix("**Date:** ") || first.hasPrefix("**Attendees:** ") {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
        // Old saved summaries mixed the transcript and repeated excerpts into notes.
        // Compact their presentation only; the editable/exported source is retained.
        if body.contains("*Extractive notes: quoted candidates require review.*") {
            if let start = body.range(of: "## Generated notes (review required)\n") {
                let tail = String(body[start.upperBound...])
                return tail.components(separatedBy: "\n## ").first ?? tail
            }
            return summary.overview
        }
        var content = body.components(separatedBy: "\n")
        if content.first == "## Generated notes (review required)" || content.first == "## Transcript highlights" { content.removeFirst() }
        content.removeAll { $0.hasPrefix("*On-device AI draft ·") || $0.hasPrefix("*AI draft ·") }
        return content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isExtractive(_ summary: MeetingSummary) -> Bool {
        !summary.markdown.contains("## Generated notes (review required)") &&
        (summary.markdown.contains("No AI summary was generated") || summary.markdown.contains("*Extractive notes:"))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let path = meeting.audioPath, meeting.platform != "transcript_import" {
                SavedRecordingPlayer(path: path, isEnabled: playbackAllowed)
            }
            if summary == nil { Text("Summary").font(.title3.weight(.semibold)) }
            if let summary {
                HStack {
                    Text("Summary").font(.title3.weight(.semibold))
                    Spacer()
                    if onSaveSummary != nil {
                        Button { showingSummaryEditor = true } label: {
                            Image(systemName: "pencil").font(.system(size: 15, weight: .medium))
                                .frame(width: 34, height: 30)
                                .minutesControlGlass(in: Capsule(), interactive: true)
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).disabled(isSummarizing)
                            .accessibilityLabel("Edit summary").help("Edit summary")
                    }
                    Menu {
                        Section(summary.markdown.contains("*On-device AI draft") ? "On-device AI draft · review against transcript" : "Summary") {
                            Button("Regenerate Summary", action: onGenerateSummary)
                                .disabled(isSummarizing || summaryDraft != summary.markdown)
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 30)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                    }
                        .buttonStyle(.plain).menuIndicator(.hidden)
                        .fixedSize().accessibilityLabel("Summary actions")
                }
                if isSummarizing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(usesAppleIntelligence ? "Writing on-device AI summary…" : "Selecting transcript highlights…").foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                }
                if isExtractive(summary) && !Summarizer.hasOnlyIntroductions(utterances: utterances, userNotes: meeting.userNotes) {
                    if FoundationModelsProvider.availability() == .available, let onEnableAppleSummary {
                        Button(action: onEnableAppleSummary) {
                            Label(usesAppleIntelligence ? "Retry AI summary" : "Use on-device AI", systemImage: "sparkles")
                                .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                                .minutesControlGlass(in: Capsule(), interactive: true)
                        }.buttonStyle(.plain).disabled(isSummarizing)
                        Text("These are source quotations. Use Apple’s local model to write a summary.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(FoundationModelsProvider.availability().message)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SummaryMarkdown(markdown: summaryBody(summary)).textSelection(.enabled)
            } else if !utterances.isEmpty {
                Button(action: onGenerateSummary) {
                    Label(isSummarizing ? (usesAppleIntelligence ? "Writing summary…" : "Selecting highlights…") : (usesAppleIntelligence ? "Summarize" : "Create transcript highlights"), systemImage: usesAppleIntelligence ? "sparkles" : "text.quote")
                        .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.disabled(isSummarizing).buttonStyle(.plain)
                    .help("Create a summary from the transcript and your notes")
            }
            Divider()
            Text("Your notes").font(.headline)
            ZStack(alignment: .topLeading) {
                if notesText.isEmpty { Text("Add notes…").font(notesFont).lineSpacing(2).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $notesText)
                    .font(notesFont).lineSpacing(2)
                    .scrollContentBackground(.hidden).scrollIndicators(.hidden)
                    .frame(minHeight: notesText.isEmpty ? 80 : 150)
                    .accessibilityLabel("Meeting notes")
                    .onChange(of: notesText) { _, value in onSaveNotes(value) }
            }
            if !utterances.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showingTranscript) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(utterances) { utterance in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Text(utterance.speakerName).font(.callout.weight(.semibold))
                                    Spacer()
                                    Button { playTranscript(utterance) } label: {
                                        Label(meeting.platform == "transcript_import" ? "Untimed" : formatTime(utterance.start), systemImage: "play.fill")
                                            .font(.caption.monospacedDigit())
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .minutesControlGlass(in: Capsule(), interactive: true)
                                    }.buttonStyle(.plain)
                                        .disabled(meeting.audioPath == nil || meeting.platform == "transcript_import")
                                        .accessibilityLabel("Play \(utterance.speakerName) at \(formatTime(utterance.start))")
                                }
                                Text(utterance.text).font(.body).lineSpacing(4).textSelection(.enabled)
                            }
                        }
                    }.padding(.top, 14)
                } label: { Text("Transcript").font(.headline) }
            }
            if meeting.audioPath != nil && meeting.platform != "transcript_import" {
                DisclosureGroup(isExpanded: $showingBookmarks) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Name this moment", text: $newBookmarkLabel)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addCurrentBookmark)
                            Button(action: addCurrentBookmark) {
                                Label(formatTime(currentMeetingPlaybackTime), systemImage: "bookmark.badge.plus")
                                    .monospacedDigit()
                            }.help("Bookmark the current playback position")
                        }
                        if bookmarks.isEmpty {
                            Text("Save a moment to find it again later.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(bookmarks.sorted { $0.timestamp < $1.timestamp }) { bookmark in
                            HStack(spacing: 12) {
                                Button {
                                    playRecording(from: bookmark.timestamp)
                                } label: {
                                    Label(formatTime(bookmark.timestamp), systemImage: "play.circle")
                                        .font(.callout.monospacedDigit())
                                }.buttonStyle(.borderless).accessibilityLabel("Play bookmark at \(formatTime(bookmark.timestamp))")
                                Text(bookmark.label).lineLimit(2)
                                Spacer()
                                Button(role: .destructive) { onDeleteBookmark(bookmark.id) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).help("Remove bookmark")
                                    .accessibilityLabel("Remove bookmark \(bookmark.label)")
                            }.padding(.vertical, 3)
                        }
                    }.padding(.top, 10)
                } label: {
                    Label(bookmarks.isEmpty ? "Bookmarks" : "Bookmarks (\(bookmarks.count))", systemImage: "bookmark")
                        .font(.callout.weight(.medium))
                }

            }
        }
        .sheet(isPresented: $showingSummaryEditor) { summaryEditor }
        .alert("Couldn’t play recording", isPresented: Binding(
            get: { transcriptPlaybackError != nil },
            set: { if !$0 { transcriptPlaybackError = nil } }
        )) { Button("OK") { transcriptPlaybackError = nil } } message: {
            Text(transcriptPlaybackError ?? "")
        }
        .onChange(of: summary?.markdown) { oldValue, value in
            if summaryDraft == (oldValue ?? "") { summaryDraft = value ?? "" }
        }
    }
    private func playTranscript(_ utterance: Utterance) {
        playRecording(from: utterance.start, to: utterance.end)
    }

    private func playRecording(from start: Double, to end: Double? = nil) {
        guard playbackAllowed, let path = meeting.audioPath, meeting.platform != "transcript_import" else { return }
        do {
            try playback.loadAudio(path: path)
            playback.play(from: start, to: end)
        } catch { transcriptPlaybackError = error.localizedDescription }
    }

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit summary").font(.title2.weight(.semibold))
            Text("Edit the Markdown used in your summary and exports.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $summaryDraft)
                .font(.body).lineSpacing(5).padding(8)
                .scrollContentBackground(.hidden)
                .background(MinutesTheme.document, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MinutesTheme.border))
                .frame(minHeight: 280).accessibilityLabel("Summary Markdown")
                .disabled(isSummarizing)
            HStack {
                Button { summaryDraft = summary?.markdown ?? "" } label: { summaryControlLabel("Revert", icon: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .disabled(summaryDraft == summary?.markdown || isSummarizing)
                Spacer()
                Button {
                    summaryDraft = summary?.markdown ?? ""
                    showingSummaryEditor = false
                } label: { summaryControlLabel("Cancel", icon: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Button { onSaveSummary?(summaryDraft); showingSummaryEditor = false } label: { summaryControlLabel("Save", icon: "checkmark") }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .disabled(isSummarizing || summaryDraft == summary?.markdown)
            }
        }.padding(24)
            .frame(minWidth: 360, idealWidth: 600, minHeight: 400)
    }

    private func summaryControlLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .minutesControlGlass(in: Capsule(), interactive: true)
    }

    private var notesFont: Font {
        #if os(iOS)
        .body
        #else
        .system(size: 13)
        #endif
    }
    private func addCurrentBookmark() {
        let label = newBookmarkLabel.trimmingCharacters(in: .whitespaces).isEmpty ? "Key moment" : newBookmarkLabel
        let bookmark = Bookmark(meetingId: meeting.id, timestamp: currentMeetingPlaybackTime, label: label)
        onSaveBookmark(bookmark)
        newBookmarkLabel = ""
    }
    private var currentMeetingPlaybackTime: Double {
        guard let path = meeting.audioPath, playback.currentAudioPath == path else { return 0 }
        return playback.currentTime
    }
    private func formatTime(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
/// Display the exported Markdown as readable native blocks; the editor retains its exact source.
@available(macOS 15.0, iOS 18.0, *)
private struct SummaryMarkdown: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let heading = line.prefix(while: { $0 == "#" }).count
                let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
                let content = isHeading ? String(line.dropFirst(heading + 1)) : line
                if content.isEmpty { Color.clear.frame(height: 4) }
                else {
                    Text((try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content))
                        .font(isHeading ? (heading == 1 ? .title2.weight(.semibold) : .headline) : .body)
                        .lineSpacing(5).padding(.top, isHeading ? 8 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

#endif
