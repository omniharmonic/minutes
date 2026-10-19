#if canImport(SwiftUI)
import SwiftUI

public struct AudioStorageEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let bytes: Int64
    public let isCompact: Bool
    public let inTrash: Bool
    public let hasTranscript: Bool
    public let canCompact: Bool

    public init(id: String, title: String, startedAt: Date, bytes: Int64, isCompact: Bool, inTrash: Bool, hasTranscript: Bool, canCompact: Bool) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.bytes = bytes
        self.isCompact = isCompact; self.inTrash = inTrash; self.hasTranscript = hasTranscript; self.canCompact = canCompact
    }
}

/// Recording storage: compress originals (playback and Regenerate keep working)
/// or delete audio once transcripts are good (notes and speakers are kept).
@available(macOS 15.0, iOS 18.0, *)
public struct AudioStorageView: View {
    let load: () async -> [AudioStorageEntry]
    let compress: ([String]) async -> Void
    let delete: ([String]) -> Void
    @State private var entries: [AudioStorageEntry] = []
    @State private var loaded = false
    @State private var working = false
    @State private var pendingDeletion: [AudioStorageEntry]?
    @State private var ageDays = 90

    public init(load: @escaping () async -> [AudioStorageEntry], compress: @escaping ([String]) async -> Void, delete: @escaping ([String]) -> Void) {
        self.load = load; self.compress = compress; self.delete = delete
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private var compressible: [AudioStorageEntry] { entries.filter(\.canCompact) }
    private var trashed: [AudioStorageEntry] { entries.filter(\.inTrash) }
    private var old: [AudioStorageEntry] {
        let cutoff = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        return entries.filter { !$0.inTrash && $0.hasTranscript && $0.startedAt < cutoff }
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Recordings", value: loaded ? "\(size(entries.reduce(0) { $0 + $1.bytes })) in \(entries.count) meetings" : "Measuring…")
                if !compressible.isEmpty {
                    // Compression measured ~2% of the original size on a real 37-minute call.
                    Button { run { await compress(compressible.map(\.id)) } } label: {
                        Label("Compress \(compressible.count) original recordings (\(size(compressible.reduce(0) { $0 + $1.bytes })))", systemImage: "arrow.down.right.and.arrow.up.left")
                    }.disabled(working)
                }
                if working { ProgressView("Working… recordings stay available while this runs.").controlSize(.small) }
            } footer: {
                Text("Compressing keeps playback and Regenerate working at about 1 MB per minute. Originals are removed only after each compressed copy is checked.")
            }
            Section("Free more space") {
                Button(role: .destructive) { pendingDeletion = trashed } label: {
                    Text("Delete audio of Recently Deleted meetings (\(size(trashed.reduce(0) { $0 + $1.bytes })))")
                }.disabled(trashed.isEmpty || working)
                Picker("Transcribed meetings older than", selection: $ageDays) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("180 days").tag(180); Text("1 year").tag(365)
                }
                Button(role: .destructive) { pendingDeletion = old } label: {
                    Text("Delete their audio (\(old.count) meetings, \(size(old.reduce(0) { $0 + $1.bytes })))")
                }.disabled(old.isEmpty || working)
            }
            Section("By meeting") {
                if loaded && entries.isEmpty { Text("No recordings are stored.").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text(badges(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(size(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Menu {
                            if entry.canCompact { Button("Compress") { run { await compress([entry.id]) } } }
                            Button("Delete Audio…", role: .destructive) { pendingDeletion = [entry] }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .buttonStyle(.borderless).fixedSize().disabled(working)
                            .accessibilityLabel("Storage actions for \(entry.title)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) {
                let ids = pendingDeletion?.map(\.id) ?? []
                pendingDeletion = nil
                delete(ids)
                Task { await reload() }
            }
        } message: { Text(deletionMessage) }
    }

    private func badges(_ entry: AudioStorageEntry) -> String {
        var parts = [entry.startedAt.formatted(date: .abbreviated, time: .omitted), entry.isCompact ? "Compressed" : "Original"]
        if !entry.hasTranscript { parts.append("Not transcribed") }
        if entry.inTrash { parts.append("Recently Deleted") }
        return parts.joined(separator: " · ")
    }

    private var deletionTitle: String {
        let items = pendingDeletion ?? []
        return items.count == 1 ? "Delete audio for “\(items[0].title)”?" : "Delete audio for \(items.count) meetings?"
    }

    private var deletionMessage: String {
        let items = pendingDeletion ?? []
        let untranscribed = items.filter { !$0.hasTranscript }.count
        let base = "Frees \(size(items.reduce(0) { $0 + $1.bytes })). Transcripts, speakers and notes are kept, but these meetings can no longer be played or regenerated."
        return untranscribed > 0 ? base + " \(untranscribed) of them have no transcript, so their recording is the only copy of what was said." : base
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task { await work(); await reload(); working = false }
    }

    private func reload() async { entries = await load(); loaded = true }
}
#endif
