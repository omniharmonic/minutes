#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSummarize
import MinutesSpeech

/// One meeting read top to bottom: listen, read the summary, look things up in the
/// transcript beside the marked moments, then your own notes.
@available(macOS 15.0, iOS 18.0, *)
public struct NotesView: View {
    public let meeting: Meeting
    @State private var notesText: String
    private let bookmarks: [Bookmark]
    @State private var summaryDraft: String = ""
    @State private var showingSummaryEditor = false
    /// nil until the person opens or closes it; wide layouts start open.
    @State private var transcriptChoice: Bool?
    @State private var transcriptPlaybackError: String?
    @State private var contentWidth: CGFloat = 0
    @State private var transcriptQuery = ""
    @State private var selectedMatch = 0
    @State private var focusedUtterance: Int?
    @State private var renamingBookmark: Bookmark?
    @State private var renameText = ""
    @FocusState private var transcriptSearchFocused: Bool
    public let onSaveSummary: ((String) -> Void)?
    public let onFindTranscript: (() -> Void)?
    public let onRegenerateRecording: (() -> Void)?
    public let onRenameBookmark: ((Bookmark, String) -> Void)?
    public let isProcessingRecording: Bool
    public let playbackAllowed: Bool
    public let isSummarizing: Bool
    public let usesAppleIntelligence: Bool
    public let onEnableAppleSummary: (() -> Void)?
    public let summary: MeetingSummary?
    public let utterances: [Utterance]
    public let attendees: [Person]
    public let findRequest: Int

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
        onEnableAppleSummary: (() -> Void)? = nil,
        onFindTranscript: (() -> Void)? = nil,
        onRegenerateRecording: (() -> Void)? = nil,
        isProcessingRecording: Bool = false,
        onRenameBookmark: ((Bookmark, String) -> Void)? = nil,
        findRequest: Int = 0
    ) {
        self.meeting = meeting
        self._notesText = State(initialValue: meeting.userNotes ?? "")
        self.bookmarks = bookmarks.sorted { $0.timestamp < $1.timestamp }
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
        self.onFindTranscript = onFindTranscript
        self.onRegenerateRecording = onRegenerateRecording
        self.isProcessingRecording = isProcessingRecording
        self.onRenameBookmark = onRenameBookmark
        self.findRequest = findRequest
        self._summaryDraft = State(initialValue: summary?.markdown ?? "")
    }

    private var showingTranscript: Bool { transcriptChoice ?? sideBySide }
    private var hasAudio: Bool { meeting.audioPath != nil && meeting.platform != "transcript_import" }
    private var timed: Bool { meeting.platform != "transcript_import" }
    /// Transcript and moments sit side by side once there is room for both.
    private var sideBySide: Bool { contentWidth >= 760 }
    #if os(iOS)
    private let actionSize: CGFloat = 44
    #else
    private let actionSize: CGFloat = 32
    #endif

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
        VStack(alignment: .leading, spacing: 28) {
            if let path = meeting.audioPath, hasAudio {
                SavedRecordingPlayer(path: path, isEnabled: playbackAllowed, onRegenerate: onRegenerateRecording,
                                     isProcessing: isProcessingRecording, bookmarks: bookmarks,
                                     onMarkMoment: { onSaveBookmark(Bookmark(meetingId: meeting.id, timestamp: $0, label: "Key moment")) })
            }
            summarySection
            if !utterances.isEmpty || !bookmarks.isEmpty {
                if sideBySide {
                    HStack(alignment: .top, spacing: 28) {
                        transcriptSection.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                        momentsSection.frame(width: min(320, max(240, contentWidth * 0.3)), alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        if !bookmarks.isEmpty || hasAudio { momentsSection }
                        transcriptSection
                    }
                }
            }
            notesSection
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = SummaryCitations.seconds(from: url) else { return .systemAction }
            jump(to: seconds)
            return .handled
        })
        .sheet(isPresented: $showingSummaryEditor) { summaryEditor }
        .alert("Couldn’t play recording", isPresented: Binding(
            get: { transcriptPlaybackError != nil },
            set: { if !$0 { transcriptPlaybackError = nil } }
        )) { Button("OK") { transcriptPlaybackError = nil } } message: {
            Text(transcriptPlaybackError ?? "")
        }
        .alert("Rename moment", isPresented: Binding(get: { renamingBookmark != nil }, set: { if !$0 { renamingBookmark = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let bookmark = renamingBookmark { rename(bookmark, to: renameText) }; renamingBookmark = nil }
            Button("Cancel", role: .cancel) { renamingBookmark = nil }
        }
        .onChange(of: summary?.markdown) { oldValue, value in
            if summaryDraft == (oldValue ?? "") { summaryDraft = value ?? "" }
        }
        // onChange, not task(id:): opening another meeting must not reopen search.
        .onChange(of: findRequest) { _, _ in beginTranscriptSearch() }
    }

    // MARK: Summary

    @ViewBuilder private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Summary").font(.title3.weight(.semibold))
                Spacer()
                if summary != nil, onSaveSummary != nil {
                    Button { showingSummaryEditor = true } label: {
                        Image(systemName: "pencil").font(.system(size: 15, weight: .medium))
                            .frame(width: actionSize + 4, height: actionSize)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).disabled(isSummarizing)
                        .accessibilityLabel("Edit summary").help("Edit summary")
                }
                Menu {
                    if let summary {
                        Section(summary.markdown.contains("*On-device AI draft") ? "On-device AI draft · review against transcript" : "Summary") {
                            Button("Regenerate Summary", systemImage: "sparkles", action: onGenerateSummary)
                                .disabled(isSummarizing || summaryDraft != summary.markdown)
                        }
                    }
                    if !utterances.isEmpty {
                        Button("Search Transcript", systemImage: "magnifyingglass", action: beginTranscriptSearch)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                        .frame(width: actionSize + 4, height: actionSize)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize().accessibilityLabel("Summary actions")
            }
            if isSummarizing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(usesAppleIntelligence ? "Writing on-device AI summary…" : "Selecting transcript highlights…").foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
            }
            if let summary {
                if isExtractive(summary) && !Summarizer.hasOnlyIntroductions(utterances: utterances, userNotes: meeting.userNotes) {
                    if FoundationModelsProvider.availability() == .available, let onEnableAppleSummary {
                        Button(action: onEnableAppleSummary) {
                            Label(usesAppleIntelligence ? "Retry AI summary" : "Use on-device AI", systemImage: "sparkles")
                                .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: actionSize)
                                .minutesControlGlass(in: Capsule(), interactive: true)
                        }.buttonStyle(.plain).disabled(isSummarizing)
                        Text("These are source quotations. Use Apple’s local model to write a summary.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(FoundationModelsProvider.availability().message)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SummaryMarkdown(markdown: SummaryCitations.linkedMarkdown(summaryBody(summary), utterances: utterances, timed: timed))
                    .textSelection(.enabled)
                    .frame(maxWidth: 780, alignment: .leading)
            } else if !utterances.isEmpty {
                Button(action: onGenerateSummary) {
                    Label(isSummarizing ? (usesAppleIntelligence ? "Writing summary…" : "Selecting highlights…") : (usesAppleIntelligence ? "Summarize" : "Create transcript highlights"), systemImage: usesAppleIntelligence ? "sparkles" : "text.quote")
                        .font(.callout.weight(.medium)).padding(.horizontal, 14).frame(minHeight: actionSize)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.disabled(isSummarizing).buttonStyle(.plain)
                    .help("Create a summary from the transcript and your notes")
            } else {
                Text("A summary appears after the recording is transcribed.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcriptSection: some View {
        let matches = TranscriptSearch.matches(in: utterances, query: transcriptQuery)
        let active = matches.indices.contains(selectedMatch) ? matches[selectedMatch] : nil
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { transcriptChoice = !showingTranscript } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showingTranscript ? 90 : 0))
                    Text("Transcript").font(.headline)
                    Text("\(utterances.count) passages").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.contentShape(Rectangle()).frame(minHeight: actionSize)
            }.buttonStyle(.plain).accessibilityValue(showingTranscript ? "Expanded" : "Collapsed")
            if showingTranscript {
                transcriptSearchField(count: matches.count)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(utterances) { utterance in
                                transcriptRow(utterance, matches: matches.filter { $0.utteranceID == utterance.id }, active: active)
                                    .id(utterance.id)
                            }
                        }.padding(.vertical, 4).padding(.trailing, 8)
                    }
                    .frame(height: sideBySide ? 560 : 460)
                    .scrollIndicators(.visible)
                    .task(id: active?.id) {
                        guard let active else { return }
                        withAnimation { proxy.scrollTo(active.utteranceID, anchor: .center) }
                    }
                    .task(id: focusedUtterance) {
                        guard let focusedUtterance else { return }
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation { proxy.scrollTo(focusedUtterance, anchor: .top) }
                    }
                }
            }
        }
        .onChange(of: transcriptQuery) { _, _ in selectedMatch = 0 }
    }

    private func transcriptSearchField(count: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this transcript", text: $transcriptQuery)
                    .textFieldStyle(.plain).focused($transcriptSearchFocused).autocorrectionDisabled()
                    .onSubmit { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: 1, count: count) }
                if !transcriptQuery.isEmpty {
                    Button { transcriptQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: actionSize + 4)
            .minutesControlGlass(in: Capsule())
            if !transcriptQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(count == 0 ? "No matches" : "\(min(selectedMatch + 1, count)) of \(count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                HStack(spacing: 0) {
                    Button { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: -1, count: count) } label: {
                        Image(systemName: "chevron.up").frame(width: actionSize, height: actionSize + 4)
                    }.accessibilityLabel("Previous match")
                    Button { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: 1, count: count) } label: {
                        Image(systemName: "chevron.down").frame(width: actionSize, height: actionSize + 4)
                    }.accessibilityLabel("Next match")
                }.buttonStyle(.plain).disabled(count == 0).minutesControlGlass(in: Capsule(), interactive: true)
            }
        }
    }

    private func transcriptRow(_ utterance: Utterance, matches: [TranscriptSearchMatch], active: TranscriptSearchMatch?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(highlight(utterance.speakerName, field: .speaker, matches: matches, active: active))
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Button { playRecording(from: utterance.start, to: utterance.end) } label: {
                    Label(timed ? SummaryCitations.timecode(utterance.start) : "Untimed", systemImage: "play.fill")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10).frame(minHeight: actionSize - 8)
                        .minutesControlGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain)
                    .disabled(!hasAudio || !playbackAllowed)
                    .accessibilityLabel("Play \(utterance.speakerName) at \(SummaryCitations.timecode(utterance.start))")
            }
            Text(highlight(utterance.text, field: .text, matches: matches, active: active))
                .font(.body).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background {
            if focusedUtterance == utterance.id { RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.14)) }
        }
    }

    private func highlight(_ text: String, field: TranscriptSearchMatch.Field, matches: [TranscriptSearchMatch], active: TranscriptSearchMatch?) -> AttributedString {
        var result = AttributedString(text)
        for match in matches where match.field == field {
            guard let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = .yellow.opacity(match == active ? 0.8 : 0.3)
            result[start..<end].foregroundColor = match == active ? .black : .primary
        }
        return result
    }

    private func beginTranscriptSearch() {
        if let onFindTranscript, utterances.isEmpty { onFindTranscript(); return }
        withAnimation(.snappy) { transcriptChoice = true }
        Task { try? await Task.sleep(for: .milliseconds(120)); transcriptSearchFocused = true }
    }

    // MARK: Moments

    private var momentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill").foregroundStyle(.yellow).font(.callout)
                Text("Moments").font(.headline)
                if !bookmarks.isEmpty { Text("\(bookmarks.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.frame(minHeight: actionSize)
            if bookmarks.isEmpty {
                Text(hasAudio ? "Tap the bookmark while recording to mark what matters. Marks also appear on the timeline above." : "No moments were marked.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(bookmarks) { bookmark in
                Button { jump(to: bookmark.timestamp) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(SummaryCitations.timecode(bookmark.timestamp))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 44).padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.22), in: Capsule())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmark.label).font(.callout.weight(.medium)).lineLimit(2)
                            if let spoken = spokenText(at: bookmark.timestamp) {
                                Text(spoken).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MinutesTheme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bookmark.label) at \(SummaryCitations.timecode(bookmark.timestamp))")
                .accessibilityHint("Plays the recording from this moment")
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { renameText = bookmark.label; renamingBookmark = bookmark }
                    Button("Remove", systemImage: "trash", role: .destructive) { onDeleteBookmark(bookmark.id) }
                }
            }
        }
    }

    private func spokenText(at seconds: Double) -> String? {
        let utterance = utterances.last { $0.start <= seconds + 0.5 } ?? utterances.first
        return utterance.map { "\($0.speakerName): \($0.text)" }
    }

    private func rename(_ bookmark: Bookmark, to label: String) {
        if let onRenameBookmark { onRenameBookmark(bookmark, label); return }
        var renamed = bookmark
        renamed.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Key moment" : label
        onSaveBookmark(renamed)
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.bottom, 6)
            Text("Your notes").font(.headline)
            ZStack(alignment: .topLeading) {
                if notesText.isEmpty { Text("Add notes…").font(notesFont).lineSpacing(2).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false) }
                TextEditor(text: $notesText)
                    .font(notesFont).lineSpacing(2)
                    .scrollContentBackground(.hidden).scrollIndicators(.hidden)
                    .frame(minHeight: notesText.isEmpty ? 90 : 160)
                    .accessibilityLabel("Meeting notes")
                    .onChange(of: notesText) { _, value in onSaveNotes(value) }
            }
        }
    }

    // MARK: Playback

    /// Plays from a cited or marked time and reveals what was said there.
    private func jump(to seconds: Double) {
        playRecording(from: seconds)
        if let utterance = utterances.last(where: { $0.start <= seconds + 0.5 }) {
            withAnimation(.snappy) { transcriptChoice = true }
            focusedUtterance = utterance.id
        }
    }

    private func playRecording(from start: Double, to end: Double? = nil) {
        guard playbackAllowed, let path = meeting.audioPath, hasAudio else { return }
        do {
            try playback.loadAudio(path: path)
            playback.play(from: start, to: end)
        } catch { transcriptPlaybackError = error.localizedDescription }
    }

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit summary").font(.title2.weight(.semibold))
            Text("Edit the Markdown used in your summary and exports. Bracketed references such as [T0006] become clickable times.")
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
            .padding(.horizontal, 14).frame(minHeight: actionSize)
            .minutesControlGlass(in: Capsule(), interactive: true)
    }

    private var notesFont: Font {
        #if os(iOS)
        .body
        #else
        .system(size: 13)
        #endif
    }
}

/// Display the exported Markdown as readable native blocks; the editor retains its exact source.
/// List items get real bullets with a hanging indent; citation links render as small times.
@available(macOS 15.0, iOS 18.0, *)
struct SummaryMarkdown: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let heading = line.prefix(while: { $0 == "#" }).count
                let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
                let indent = line.prefix(while: { $0 == " " }).count
                let trimmed = line.drop(while: { $0 == " " })
                let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                let content = isHeading ? String(line.dropFirst(heading + 1)) : (isBullet ? String(trimmed.dropFirst(2)) : line)
                if content.trimmingCharacters(in: .whitespaces).isEmpty { Color.clear.frame(height: 4) }
                else if isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Color.primary.opacity(0.55)).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        inline(content).font(.body)
                    }
                    .padding(.leading, CGFloat(min(indent, 8)) * 8)
                } else {
                    inline(content)
                        .font(isHeading ? (heading <= 2 ? .title3.weight(.semibold) : (heading == 3 ? .headline : .subheadline.weight(.semibold))) : .body)
                        .foregroundStyle(heading >= 4 ? Color.secondary : Color.primary)
                        .padding(.top, isHeading ? 10 : 0)
                }
            }
        }
    }

    private func inline(_ content: String) -> some View {
        var text = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
        for run in text.runs where run.link?.scheme == SummaryCitations.seekScheme {
            text[run.range].font = .caption.monospacedDigit().weight(.semibold)
            text[run.range].foregroundColor = Color(red: 0.72, green: 0.55, blue: 0.0)
            text[run.range].underlineStyle = nil
        }
        return Text(text).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
