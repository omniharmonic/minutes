#if canImport(SwiftUI)
import SwiftUI
import MinutesCalendar

/// Links a saved recording to the calendar event it belonged to, so its
/// invitees are offered during speaker review. Events load only when opened.
@available(macOS 15.0, iOS 18.0, *)
public struct CalendarLinkButton: View {
    let load: () async -> [CalendarMeetingEvent]
    let link: (CalendarMeetingEvent) -> Void
    @State private var events: [CalendarMeetingEvent]?
    @State private var showing = false

    public init(load: @escaping () async -> [CalendarMeetingEvent], link: @escaping (CalendarMeetingEvent) -> Void) {
        self.load = load; self.link = link
    }

    public var body: some View {
        Button { showing = true } label: {
            Label("Link calendar event", systemImage: "calendar.badge.plus")
                .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .help("Attach this recording to its calendar event so invitees are suggested as speakers.")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Calendar events near this recording").font(.headline)
                if let events {
                    if events.isEmpty {
                        Text("No timed events overlap this recording. Connect a calendar in Settings if none is connected.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(events) { event in
                        Button { link(event); showing = false } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.body.weight(.medium))
                                Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.attendees.count) invited")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16).frame(width: 320)
            .task { events = await load() }
        }
    }
}
#endif
