#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

@available(macOS 15.0, iOS 18.0, *)
public struct MeetingFolderEditor: View {
    private let title: String
    private let onSave: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var error: String?

    public init(title: String, name: String = "", description: String = "", onSave: @escaping (String, String) throws -> Void) {
        self.title = title; self.onSave = onSave
        _name = State(initialValue: name); _description = State(initialValue: description)
    }
    public var body: some View {
        NavigationStack {
            Form {
                Section("Folder name") {
                    TextField("Name", text: $name).accessibilityIdentifier("folder.name")
                }
                Section {
                    TextField("What belongs in this folder?", text: $description, axis: .vertical)
                        .lineLimit(3...6).accessibilityIdentifier("folder.description")
                } header: { Text("Description") } footer: {
                    Text("Optional context for on-device filing, such as a project, recurring call, or topic.")
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), description); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("folder.save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 340)
        #endif
    }
}

/// Destination buttons work inside both a context menu and a detail actions menu.
@available(macOS 15.0, iOS 18.0, *)
public struct MeetingFolderDestinations: View {
    let folders: [MeetingFolder]
    let onMove: (String?) -> Void
    public init(folders: [MeetingFolder], onMove: @escaping (String?) -> Void) {
        self.folders = folders; self.onMove = onMove
    }
    public var body: some View {
        Button { onMove(nil) } label: { Label("Unfiled", systemImage: "tray") }
        ForEach(folders) { folder in
            Button { onMove(folder.id) } label: { Label(folder.name, systemImage: "folder") }
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
public struct MeetingFolderManager: View {
    let folders: [MeetingFolder]
    let count: (String) -> Int
    @Binding var autoFile: Bool
    let canOrganize: Bool
    let isOrganizing: Bool
    let organizationMessage: String
    let onCreate: (String, String) throws -> Void
    let onUpdate: (String, String, String) throws -> Void
    let onDelete: (String) throws -> Void
    let onOrganize: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var editing: MeetingFolder?
    @State private var deleting: MeetingFolder?
    @State private var error: String?

    public init(folders: [MeetingFolder], count: @escaping (String) -> Int, autoFile: Binding<Bool>, canOrganize: Bool, isOrganizing: Bool = false, organizationMessage: String = "",
                onCreate: @escaping (String, String) throws -> Void, onUpdate: @escaping (String, String, String) throws -> Void,
                onDelete: @escaping (String) throws -> Void, onOrganize: @escaping () -> Void) {
        self.folders = folders; self.count = count; _autoFile = autoFile; self.canOrganize = canOrganize
        self.isOrganizing = isOrganizing; self.organizationMessage = organizationMessage
        self.onCreate = onCreate; self.onUpdate = onUpdate; self.onDelete = onDelete; self.onOrganize = onOrganize
    }
    public var body: some View {
        NavigationStack {
            Form {
                Section("Your folders") {
                    ForEach(folders) { folder in
                        HStack(spacing: 12) {
                            Button { editing = folder } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder").foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.name).foregroundStyle(.primary)
                                        if !folder.description.isEmpty { Text(folder.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    Spacer()
                                    Text(count(folder.id), format: .number).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Edit \(folder.name)")
                            Button(role: .destructive) { deleting = folder } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("Delete \(folder.name)")
                        }.padding(.vertical, 4)
                    }
                    if folders.isEmpty { Text("Create a folder to organize your meetings.").foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Automatically file new meetings", isOn: $autoFile)
                    Button(isOrganizing ? "Organizing…" : "Organize Unfiled Meetings", action: onOrganize)
                        .disabled(!canOrganize || folders.isEmpty || isOrganizing)
                    if isOrganizing { ProgressView().controlSize(.small) }
                    if !organizationMessage.isEmpty { Text(organizationMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                } header: { Text("On-device organization") } footer: {
                    Text("Uses folder names and descriptions. You can always move a meeting yourself.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
            }
            .sheet(isPresented: $creating) { MeetingFolderEditor(title: "New Folder", onSave: onCreate) }
            .sheet(item: $editing) { folder in
                MeetingFolderEditor(title: "Edit Folder", name: folder.name, description: folder.description) {
                    try onUpdate(folder.id, $0, $1)
                }
            }
            .confirmationDialog("Delete folder?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { folder in
                Button("Delete Folder", role: .destructive) {
                    do { try onDelete(folder.id); deleting = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { folder in Text("Meetings in \(folder.name) will remain saved and move to Unfiled.") }
            .alert("Could not delete folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        #if os(macOS)
        .frame(width: 520, height: 460)
        #endif
    }
}
#endif
