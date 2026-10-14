#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesExport

@available(macOS 15.0, iOS 18.0, *)
public struct TranscriptView: View {
    @State public var utterances: [Utterance]
    public let availableSpeakers: [String]
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
    
    // Export Status Banner State
    @State private var exportStatusMessage: String? = nil
    @State private var isExportSuccess: Bool = true
    
    public init(
        utterances: [Utterance],
        availableSpeakers: [String] = [],
        onSeek: @escaping (Double) -> Void = { _ in },
        onUtteranceEdited: ((Utterance) -> Void)? = nil,
        onSpeakerReassigned: ((Int, String) -> Void)? = nil,
        onExportParachute: (() -> Void)? = nil,
        onExportMarkdown: (() -> Void)? = nil
    ) {
        self._utterances = State(initialValue: utterances)
        self.availableSpeakers = availableSpeakers
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
            // Header: Search Bar & One-Click Exports
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Search Bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(MinutesTheme.muted)
                        TextField("Search transcript text or speaker...", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(MinutesTheme.text)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(MinutesTheme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(MinutesTheme.cardHover)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MinutesTheme.border, lineWidth: 1))
                    
                    // One-Click Native Exports
                    if let onExportParachute = onExportParachute {
                        Button(action: {
                            onExportParachute()
                            exportStatusMessage = "Exported to Parachute Vault (localhost:1940)"
                            isExportSuccess = true
                        }) {
                            Label("Parachute Vault", systemImage: "archivebox.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MinutesTheme.primary)
                    }
                    
                    if let onExportMarkdown = onExportMarkdown {
                        Button(action: {
                            onExportMarkdown()
                            exportStatusMessage = "Exported Markdown (~/Documents/Minutes)"
                            isExportSuccess = true
                        }) {
                            Label("Obsidian", systemImage: "doc.text.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                // Status Toast / Banner
                if let msg = exportStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: isExportSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isExportSuccess ? MinutesTheme.emerald : Color.red)
                        Text(msg)
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.text)
                        Spacer()
                        Button(action: { exportStatusMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(MinutesTheme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isExportSuccess ? MinutesTheme.emeraldBg : Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
            .background(MinutesTheme.card)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(MinutesTheme.border),
                alignment: .bottom
            )
            
            // Utterance Stream
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if filteredUtterances.isEmpty {
                        Text("No matching utterances found.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                            .padding(24)
                    } else {
                        ForEach(filteredUtterances) { u in
                            utteranceRow(u)
                        }
                    }
                }
                .padding(20)
            }
            .background(MinutesTheme.bg)
        }
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
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(speakerColor(u.speakerName))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(speakerColor(u.speakerName).opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(speakerColor(u.speakerName).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                
                // Timestamp Seek Button
                Button(action: { onSeek(u.start) }) {
                    Text(formatTime(u.start))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MinutesTheme.muted)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Edit Button Toggle
                Button(action: {
                    if editingUtteranceId == u.id {
                        commitInlineEdit(for: u.id)
                    } else {
                        editingUtteranceId = u.id
                        editingText = u.text
                    }
                }) {
                    Image(systemName: editingUtteranceId == u.id ? "checkmark.circle.fill" : "pencil")
                        .font(.caption)
                        .foregroundStyle(editingUtteranceId == u.id ? MinutesTheme.emerald : MinutesTheme.muted)
                }
                .buttonStyle(.plain)
            }
            
            // Text or Inline Editor
            if editingUtteranceId == u.id {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Utterance text", text: $editingText, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(MinutesTheme.cardHover)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MinutesTheme.primary, lineWidth: 1))
                        .onSubmit {
                            commitInlineEdit(for: u.id)
                        }
                    
                    HStack {
                        Button("Save") {
                            commitInlineEdit(for: u.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MinutesTheme.primary)
                        .controlSize(.small)
                        
                        Button("Cancel") {
                            editingUtteranceId = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                Text(u.text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(MinutesTheme.text)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editingUtteranceId = u.id
                        editingText = u.text
                    }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(editingUtteranceId == u.id ? MinutesTheme.card : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(MinutesTheme.border.opacity(0.3)),
            alignment: .bottom
        )
    }
    
    private func commitInlineEdit(for utteranceId: Int) {
        guard let idx = utterances.firstIndex(where: { $0.id == utteranceId }) else { return }
        utterances[idx].text = editingText
        editingUtteranceId = nil
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
        set.insert("Speaker 1")
        set.insert("Speaker 2")
        return Array(set).sorted()
    }
    
    private func formatTime(_ sec: Double) -> String {
        let mins = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", mins, s)
    }
    
    private func speakerColor(_ name: String) -> Color {
        let colors: [Color] = [MinutesTheme.blue, MinutesTheme.purple, MinutesTheme.emerald, MinutesTheme.primary]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}

// MARK: - Summary View

@available(macOS 15.0, iOS 18.0, *)
public struct SummaryView: View {
    public let summary: MeetingSummary
    public let onExportParachute: () -> Void
    public let onExportMarkdown: () -> Void
    
    @State private var exportToast: String? = nil
    
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
                            .foregroundStyle(MinutesTheme.text)
                        Text("Generated On-Device · FluidAudio Parakeet Ultra")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    Spacer()
                    Button("Export to Parachute", action: {
                        onExportParachute()
                        exportToast = "Exported to Parachute Vault (localhost:1940)"
                    })
                    .buttonStyle(.borderedProminent)
                    .tint(MinutesTheme.primary)
                    
                    Button("Export Markdown", action: {
                        onExportMarkdown()
                        exportToast = "Saved to ~/Documents/Minutes"
                    })
                    .buttonStyle(.bordered)
                }
                
                if let toast = exportToast {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MinutesTheme.emerald)
                        Text(toast)
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.text)
                        Spacer()
                    }
                    .padding(10)
                    .background(MinutesTheme.emeraldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                
                // Overview
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXECUTIVE OVERVIEW")
                        .font(.caption.bold())
                        .foregroundStyle(MinutesTheme.primary)
                    Text(summary.overview)
                        .font(.body)
                        .lineSpacing(4)
                        .foregroundStyle(MinutesTheme.text)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MinutesTheme.cardHover)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                // Decisions
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("KEY DECISIONS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.emerald)
                        ForEach(summary.decisions, id: \.self) { d in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MinutesTheme.emerald)
                                    .font(.subheadline)
                                Text(d)
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.text)
                            }
                        }
                    }
                    .padding(14)
                    .minutesCard()
                }
                
                // Action items
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ACTION ITEMS")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.purple)
                        ForEach(summary.actionItems, id: \.text) { a in
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .foregroundStyle(MinutesTheme.muted)
                                Text(a.text)
                                    .font(.subheadline)
                                    .foregroundStyle(MinutesTheme.text)
                                Spacer()
                                if let owner = a.owner {
                                    Text("@\(owner)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(MinutesTheme.primary.opacity(0.15))
                                        .foregroundStyle(MinutesTheme.primary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(14)
                    .minutesCard()
                }
            }
            .padding(20)
        }
        .background(MinutesTheme.bg)
    }
}
#endif
