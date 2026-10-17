#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesExport

@available(macOS 15.0, iOS 18.0, *)
public struct TranscriptView: View {
    @State public var utterances: [Utterance]
    public let availableSpeakers: [String]
    public let timestampsAvailable: Bool
    public let onSeek: (Double) -> Void
    public let onUtteranceEdited: ((Utterance) -> Void)?
    public let onSpeakerReassigned: ((Int, String) -> Void)?
    public let onExportParachute: (() -> Void)?
    public let onExportMarkdown: (() -> Void)?
    
    // Search State
    @State private var searchText: String = ""
    
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
        self.onSeek = onSeek
        self.onUtteranceEdited = onUtteranceEdited
        self.onSpeakerReassigned = onSpeakerReassigned
        self.onExportParachute = onExportParachute
        self.onExportMarkdown = onExportMarkdown
    }
    
    private var filteredUtterances: [Utterance] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return utterances
        }
        return utterances.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            $0.speakerName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in transcript", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .minutesGlass()
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if filteredUtterances.isEmpty {
                        ContentUnavailableView(searchText.isEmpty ? "No transcript yet" : "No matches",
                                               systemImage: searchText.isEmpty ? "text.alignleft" : "magnifyingglass",
                                               description: Text(searchText.isEmpty ? "Recorded speech appears here after processing." : "Try a different word or speaker name."))
                    }
                    ForEach(filteredUtterances) { utterance in
                        utteranceRow(utterance)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
        }
        .background(MinutesTheme.document)
        .sheet(isPresented: $showingEditor) { transcriptEditor }
        .onChange(of: incomingRevision) { _, _ in
            // Keep the editor's draft while refreshing saved text and speaker names.
            utterances = incomingUtterances
            if let id = editingUtteranceId, !utterances.contains(where: { $0.id == id }) {
                editingUtteranceId = nil
                showingEditor = false
            }
        }
    }

    private var incomingRevision: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(incomingUtterances)
    }

    // MARK: - Utterance Row
    
    @ViewBuilder
    private func utteranceRow(_ u: Utterance) -> some View {
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
                        Text(u.speakerName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
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
            Text(u.text)
                .font(.body)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Edit Transcript…") { beginEditing(u) } }

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
