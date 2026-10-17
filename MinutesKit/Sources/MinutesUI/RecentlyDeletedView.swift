#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

@available(macOS 15.0, iOS 18.0, *)
public struct RecentlyDeletedView: View {
    public let load: () -> [Meeting]
    public let restore: (String) throws -> Void
    @State private var meetings: [Meeting] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    public init(load: @escaping () -> [Meeting], restore: @escaping (String) throws -> Void) {
        self.load = load; self.restore = restore
    }
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(meetings) { meeting in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(meeting.title).lineLimit(2)
                                Text(meeting.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                do { try restore(meeting.id); meetings = load() } catch { self.error = error.localizedDescription }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                } footer: { Text("Deleted meetings and their audio stay on this device until restored. Saved voice profiles and exported copies are unchanged.") }
            }
            .overlay { if meetings.isEmpty { ContentUnavailableView("No deleted meetings", systemImage: "trash") } }
            .navigationTitle("Recently Deleted")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { meetings = load() }
            .alert("Could not restore meeting", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}
#endif
