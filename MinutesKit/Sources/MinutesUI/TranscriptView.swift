#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesExport

@available(macOS 15.0, iOS 18.0, *)
public struct TranscriptView: View {
    @State public var utterances: [Utterance]
    public let availableSpeakers: [String]
    public let timestampsAvailable: Bool
    public let findRequest: Int
    public let onSeek: (Double) -> Void
    public let onUtteranceEdited: ((Utterance) -> Void)?
    public let onSpeakerReassigned: ((Int, String) -> Void)?
    public let onExportParachute: (() -> Void)?
    public let onExportMarkdown: (() -> Void)?
    
    // Search State
    @State private var searchText: String = ""
    @State private var selectedMatch = 0
    @FocusState private var searchFocused: Bool
    
    // Inline Edit State
    @State private var editingUtteranceId: Int? = nil
    @State private var editingText: String = ""
    @State private var showingEditor = false
    @FocusState private var editorFocused: Bool
    
    private let incomingUtterances: [Utterance]
    
    public init(
        utterances: [Utterance],
        availableSpeakers: [String] = [],
        clusters: [SpeakerCluster] = [],
        timestampsAvailable: Bool = true,
        findRequest: Int = 0,
        onSeek: @escaping (Double) -> Void = { _ in },
        onUtteranceEdited: ((Utterance) -> Void)? = nil,
        onSpeakerReassigned: ((Int, String) -> Void)? = nil,
        onExportParachute: (() -> Void)? = nil,
        onExportMarkdown: (() -> Void)? = nil
    ) {
        let readable = TranscriptSpeakerLabels.readableUtterances(utterances, clusters: clusters)
        self._utterances = State(initialValue: readable)
        self.incomingUtterances = readable
        self.availableSpeakers = availableSpeakers
        self.timestampsAvailable = timestampsAvailable
        self.findRequest = findRequest
        self.onSeek = onSeek
        self.onUtteranceEdited = onUtteranceEdited
        self.onSpeakerReassigned = onSpeakerReassigned
        self.onExportParachute = onExportParachute
        self.onExportMarkdown = onExportMarkdown
    }
    
    public var body: some View {
        let matches = TranscriptSearch.matches(in: utterances, query: searchText)
        let byUtterance = Dictionary(grouping: matches, by: \.utteranceID)
        let active = matches.indices.contains(selectedMatch) ? matches[selectedMatch] : nil
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                searchBar(count: matches.count)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if utterances.isEmpty {
                            ContentUnavailableView("No transcript yet", systemImage: "text.alignleft",
                                description: Text("Recorded speech appears here after processing."))
                        }
                        ForEach(utterances) { utterance in
                            utteranceRow(utterance, matches: byUtterance[utterance.id] ?? [], active: active)
                                .id(utterance.id)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .onChange(of: searchText) { _, _ in
                selectedMatch = 0
            }
            .task(id: active?.id) {
                guard let active else { return }
                // Materialize a distant lazy row, then target its matching paragraph.
                proxy.scrollTo(active.utteranceID, anchor: .center)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(active.id, anchor: .center)
            }
            .onChange(of: incomingRevision) { _, _ in
                utterances = incomingUtterances
                selectedMatch = 0
                if let id = editingUtteranceId, !utterances.contains(where: { $0.id == id }) {
                    editingUtteranceId = nil
                    showingEditor = false
                }
            }
        }
        .background(MinutesTheme.document)
        .sheet(isPresented: $showingEditor) { transcriptEditor }
        .task(id: findRequest) {
            guard findRequest > 0 else { return }
            // A newly selected transcript must be attached before it can focus.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
    }

    private func searchBar(count: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $searchText)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .autocorrectionDisabled()
                    .onSubmit { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: 1, count: count) }
                    .accessibilityLabel("Find in this transcript")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .minutesControlGlass(in: Capsule())
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(count == 0 ? "No matches" : "\(min(selectedMatch + 1, count)) of \(count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize().accessibilityLabel("Transcript search results")
                    .accessibilityValue(count == 0 ? "No matches" : "\(min(selectedMatch + 1, count)) of \(count)")
                HStack(spacing: 0) {
                    Button { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: -1, count: count) } label: {
                        Image(systemName: "chevron.up").frame(width: 36, height: 40)
                    }.accessibilityLabel("Previous transcript match")
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button { selectedMatch = TranscriptSearch.advancedIndex(selectedMatch, by: 1, count: count) } label: {
                        Image(systemName: "chevron.down").frame(width: 36, height: 40)
                    }.accessibilityLabel("Next transcript match")
                        .keyboardShortcut("g", modifiers: .command)
                }.buttonStyle(.plain).disabled(count == 0)
                    .minutesControlGlass(in: Capsule(), interactive: true)
            }
        }
    }

    private func highlighted(_ text: String, field: TranscriptSearchMatch.Field, matches: [TranscriptSearchMatch], active: TranscriptSearchMatch?) -> AttributedString {
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

    private var incomingRevision: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(incomingUtterances)
    }

    // MARK: - Utterance Row
    
    @ViewBuilder
    private func utteranceRow(_ u: Utterance, matches: [TranscriptSearchMatch], active: TranscriptSearchMatch?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Per-utterance Speaker Re-tagging Dropdown
                Menu {
                    ForEach(speakersForPicker(current: u.speakerName), id: \.self) { speaker in
                        Button(speaker) {
                            reassignSpeaker(utteranceId: u.id, newSpeaker: speaker)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(highlighted(u.speakerName, field: .speaker, matches: matches, active: active))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .id(active?.utteranceID == u.id && active?.field == .speaker ? active!.id : "speaker-\(u.id)")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                }
                .buttonStyle(.plain)
                
                // Untimed text imports never imply a verified audio position.
                Button(action: { if timestampsAvailable { onSeek(u.start) } }) {
                    Text(timestampsAvailable ? formatTime(u.start) : "Untimed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MinutesTheme.muted)
                }
                .buttonStyle(.plain)
                .disabled(!timestampsAvailable)
                
                Spacer()
                
                Button { beginEditing(u) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit transcript")
                .accessibilityLabel("Edit transcript at \(timestampsAvailable ? formatTime(u.start) : "untimed segment")")
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(textBlocks(u.text)) { block in
                    let blockMatches = matches.filter { $0.field == .text }.compactMap { match -> TranscriptSearchMatch? in
                        let intersection = NSIntersectionRange(match.range, NSRange(location: block.offset, length: block.text.utf16.count))
                        guard intersection.length > 0 else { return nil }
                        return TranscriptSearchMatch(utteranceID: match.utteranceID, field: .text,
                            location: intersection.location - block.offset, length: intersection.length)
                    }
                    let blockActive = active.flatMap { value -> TranscriptSearchMatch? in
                        guard value.field == .text else { return nil }
                        return blockMatches.first { $0.location + block.offset == value.location && value.utteranceID == u.id }
                    }
                    Text(highlighted(block.text, field: .text, matches: blockMatches, active: blockActive))
                        .font(.body).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(blockActive != nil ? active!.id : "text-\(u.id)-\(block.offset)")
                }
            }
            .contextMenu { Button("Edit Transcript…") { beginEditing(u) } }


        }
    }

    private struct TextBlock: Identifiable {
        let text: String
        let offset: Int
        var id: Int { offset }
    }
    private func textBlocks(_ text: String) -> [TextBlock] {
        var offset = 0
        return text.components(separatedBy: "\n\n").map { part in
            defer { offset += part.utf16.count + 2 }
            return TextBlock(text: part, offset: offset)
        }
    }

    private func beginEditing(_ utterance: Utterance) {
        editingUtteranceId = utterance.id
        editingText = utterance.text
        showingEditor = true
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit transcript").font(.title2.weight(.semibold))
                Spacer()
                if let utterance = utterances.first(where: { $0.id == editingUtteranceId }) {
                    Text(utterance.speakerName).foregroundStyle(.secondary)
                }
            }
            Text("Correct the words in this segment. The original audio is unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $editingText)
                .font(.body).lineSpacing(5)
                .padding(8)
                .background(MinutesTheme.document, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MinutesTheme.border))
                .focused($editorFocused)
                .accessibilityLabel("Transcript text")
                .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingEditor = false; editingUtteranceId = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { if let id = editingUtteranceId { commitInlineEdit(for: id) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 520, minHeight: 300)
        .onAppear { editorFocused = true }
    }

    private func commitInlineEdit(for utteranceId: Int) {
        guard let idx = utterances.firstIndex(where: { $0.id == utteranceId }) else { return }
        utterances[idx].text = editingText
        editingUtteranceId = nil
        showingEditor = false
        onUtteranceEdited?(utterances[idx])
    }
    
    private func reassignSpeaker(utteranceId: Int, newSpeaker: String) {
        guard let idx = utterances.firstIndex(where: { $0.id == utteranceId }) else { return }
        utterances[idx].speakerName = newSpeaker
        onSpeakerReassigned?(utteranceId, newSpeaker)
        onUtteranceEdited?(utterances[idx])
    }
    
    private func speakersForPicker(current: String) -> [String] {
        var set = Set(availableSpeakers)
        set.insert(current)
        set.formUnion(utterances.map(\.speakerName))
        return Array(set).sorted()
    }
    
    private func formatTime(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", mins, s)
    }
    
}

// MARK: - Summary View

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
            VStack(alignment: .leading, spacing: 28) {
                Text(summary.overview)
                    .lineSpacing(5)
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Decisions").font(.headline)
                        ForEach(summary.decisions, id: \.self) { decision in
                            Text("• " + decision)
                        }
                    }
                }
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Action items").font(.headline)
                        ForEach(summary.actionItems, id: \.text) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("• " + item.text)
                                if let owner = item.owner {
                                    Text(owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }
}
#endif
