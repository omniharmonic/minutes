import SwiftUI
import MinutesCore
import MinutesUI

struct IOSPeopleDirectory: View {
    @ObservedObject var state: AppState
    @State private var search = ""
    private var people: [Person] {
        state.store.listPeople().filter { person in
            search.isEmpty || person.displayName.localizedCaseInsensitiveContains(search) ||
                person.emails.contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    var body: some View {
        List(people) { person in
            NavigationLink { IOSPersonCalls(state: state, person: person) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(person.displayName).font(.headline)
                    if let email = person.emails.first { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
        }
        .navigationTitle("People")
        .searchable(text: $search, prompt: "Name or email")
        .overlay {
            if people.isEmpty {
                ContentUnavailableView("No People", systemImage: "person.2", description: Text("Record a calendar meeting or confirm a speaker to start a call history."))
            }
        }
    }
}

private struct IOSPersonCalls: View {
    @ObservedObject var state: AppState
    let person: Person
    @State private var history: [PersonMeetingHistoryEntry] = []
    @State private var error: String?
    var body: some View {
        List {
            if !person.emails.isEmpty {
                Section("Email") { ForEach(person.emails, id: \.self) { Text($0).textSelection(.enabled) } }
            }
            Section("Voice") {
                NavigationLink {
                    IOSPersonVoice(state: state, personID: person.id)
                } label: { Label("Connect or manage voice", systemImage: "waveform") }
            }
            Section("Recent Calls") {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { refresh() }
                } else if history.isEmpty {
                    Text("No linked calls on this device yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(history) { entry in
                        NavigationLink { IOSMeetingDetail(state: state, meetingID: entry.meeting.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.meeting.title).font(.headline)
                                Text(entry.meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                                Text(context(entry)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
            Section {
                Text("Calendar invitations link calls by email. They do not confirm who spoke. Call history and remembered voices stay on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(person.displayName).navigationBarTitleDisplayMode(.inline)
            .onAppear { refresh() }.refreshable { refresh() }
    }
    private func refresh() {
        do { history = try state.store.listMeetings(forPersonId: person.id, limit: 100); error = nil }
        catch { self.error = "Could not load call history. Please try again." }
    }
    private func context(_ entry: PersonMeetingHistoryEntry) -> String {
        var labels: [String] = []
        if entry.calendarInvitee { labels.append("Calendar invitee") }
        if entry.confirmedSpeaker { labels.append("Confirmed speaker") }
        if entry.recognizedSpeaker { labels.append("Recognized voice") }
        if entry.speakerLinked && !entry.confirmedSpeaker && !entry.recognizedSpeaker { labels.append("Speaker needs review") }
        return labels.joined(separator: " · ")
    }
}

private struct IOSPersonVoice: View {
    @ObservedObject var state: AppState
    let personID: String
    @State private var selection: String?
    var body: some View {
        VoiceprintHubView(store: state.store, selection: $selection, showsList: false,
            playbackAllowed: !state.isRecording && !state.isStartingRecording && !state.isFinalizingRecording)
        .onAppear { selection = personID }
        .onDisappear { state.voiceprints = state.store.listVoiceprints() }
        .navigationTitle("Voice").navigationBarTitleDisplayMode(.inline)
    }
}
