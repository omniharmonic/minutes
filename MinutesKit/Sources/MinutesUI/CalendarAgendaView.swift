#if canImport(SwiftUI)
import SwiftUI
import MinutesCalendar

/// Calendar presentation only. Authentication, permissions and recording remain with the caller.
@available(macOS 15.0, iOS 18.0, *)
public struct CalendarAgendaView: View {
    public let events: [CalendarMeetingEvent]
    public let sourceName: String
    public let isConnected: Bool
    public let isRefreshing: Bool
    public let isConnecting: Bool
    public let statusMessage: String
    public let recordingUnavailableReason: String?
    public let compact: Bool
    public let showsConnectionControls: Bool
    public let selectedEventID: String?
    public let onRefresh: () -> Void
    public let onConnect: () -> Void
    public let onOpenSettings: () -> Void
    public let onRecord: (CalendarMeetingEvent) -> Void
    public let onSelect: ((CalendarMeetingEvent) -> Void)?
    public let onEnableNotifications: (() -> Void)?
    public let notificationsEnabled: Bool

    public init(events: [CalendarMeetingEvent], sourceName: String, isConnected: Bool,
                isRefreshing: Bool = false, isConnecting: Bool = false, statusMessage: String,
                recordingUnavailableReason: String? = nil, compact: Bool = false,
                selectedEventID: String? = nil, showsConnectionControls: Bool = true, onRefresh: @escaping () -> Void,
                onConnect: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
                onRecord: @escaping (CalendarMeetingEvent) -> Void,
                onSelect: ((CalendarMeetingEvent) -> Void)? = nil,
                notificationsEnabled: Bool = false, onEnableNotifications: (() -> Void)? = nil) {
        self.events = events; self.sourceName = sourceName; self.isConnected = isConnected
        self.isRefreshing = isRefreshing; self.isConnecting = isConnecting; self.statusMessage = statusMessage
        self.recordingUnavailableReason = recordingUnavailableReason; self.compact = compact
        self.showsConnectionControls = showsConnectionControls
        self.selectedEventID = selectedEventID; self.onRefresh = onRefresh; self.onConnect = onConnect
        self.onOpenSettings = onOpenSettings; self.onRecord = onRecord; self.onSelect = onSelect
        self.notificationsEnabled = notificationsEnabled; self.onEnableNotifications = onEnableNotifications
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsConnectionControls {
                connectionHeader.padding(compact ? 16 : 24)
                Divider()
            }
            if !showsConnectionControls && isConnected &&
                (statusMessage.localizedCaseInsensitiveContains("failed") || statusMessage.localizedCaseInsensitiveContains("unavailable")) {
                Label(statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(24)
            }
            if !isConnected {
                emptyState(title: "Bring your meetings into Minutes", symbol: "calendar.badge.plus",
                           detail: "Connect Apple Calendar or Google Calendar in the app’s Settings. You choose when to record.")
            } else if events.isEmpty {
                if isRefreshing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking upcoming meetings…").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                } else {
                    emptyState(title: "No meetings to show", symbol: "calendar",
                               detail: "Refresh to check your selected calendar. You can record a meeting from All Meetings at any time.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 8 : 20) {
                        ForEach(dayGroups, id: \.day) { group in
                            Text(group.day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                                .font(compact ? .caption.weight(.semibold) : .headline)
                                .foregroundStyle(.secondary).padding(.top, 8)
                            ForEach(group.events) { event in
                                if compact {
                                    Button { onSelect?(event) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(event.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(3)
                                            Text(event.start, format: .dateTime.hour().minute())
                                                .font(.caption).foregroundStyle(.secondary)
                                            if !event.attendees.isEmpty {
                                                Text(event.attendees.prefix(3).map(\.displayName).joined(separator: ", "))
                                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                            .background(selectedEventID == event.id ? Color.accentColor.opacity(0.10) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 12))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .accessibilityAddTraits(selectedEventID == event.id ? .isSelected : [])
                                } else {
                                    NavigationLink {
                                        ScrollView {
                                            CalendarEventDetailView(event: event, sourceName: sourceName,
                                                recordingUnavailableReason: recordingUnavailableReason,
                                                onRecord: { onRecord(event) })
                                                .padding(24)
                                        }
                                        .background(MinutesTheme.document)
                                        .navigationTitle("Meeting")
                                    } label: {
                                        HStack(alignment: .top, spacing: 14) {
                                            VStack(alignment: .leading, spacing: 7) {
                                                Text(event.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                                Text(event.start, format: .dateTime.hour().minute())
                                                    .font(.subheadline).foregroundStyle(.secondary)
                                                if !event.attendees.isEmpty {
                                                    Text(event.attendees.prefix(3).map(\.displayName).joined(separator: ", "))
                                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary).padding(.top, 5)
                                        }.padding(.vertical, 12).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }.padding(compact ? 12 : 24)
                }
            }
        }.background(compact ? MinutesTheme.bg : MinutesTheme.document)
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceName).font(.headline)
                    Text(isConnected ? "Connected · read-only access" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isRefreshing || isConnecting { ProgressView().controlSize(.small).accessibilityLabel(isConnecting ? "Connecting calendar" : "Refreshing calendar") }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { connectionActions }
                VStack(alignment: .leading, spacing: 8) { connectionActions }
            }
            if !statusMessage.isEmpty {
                DisclosureGroup {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.top, 6)
                } label: {
                    Text(statusMessage).lineLimit(compact ? 2 : 3)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if isConnected, let onEnableNotifications {
                if notificationsEnabled {
                    Label("Meeting reminders enabled", systemImage: "bell.badge")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: onEnableNotifications) {
                        Label("Enable meeting reminders", systemImage: "bell")
                            .font(.caption).padding(.horizontal, 12).frame(height: 30)
                            .minutesControlGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var connectionActions: some View {
        Button(action: isConnected ? onRefresh : onConnect) {
            Label(isConnected ? "Refresh" : "Connect Apple Calendar", systemImage: isConnected ? "arrow.clockwise" : "calendar.badge.plus")
                .font(.callout.weight(.medium)).padding(.horizontal, 12).frame(height: 34)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }.buttonStyle(.plain).disabled(isRefreshing || isConnecting)
        Button(action: onOpenSettings) {
            Label("Settings", systemImage: "slider.horizontal.3")
                .font(.callout).padding(.horizontal, 12).frame(height: 34)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }.buttonStyle(.plain).accessibilityLabel("Calendar settings")
    }

    private func emptyState(title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: compact ? .leading : .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(compact ? .leading : .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(compact ? 20 : 32)
    }

    private var dayGroups: [(day: Date, events: [CalendarMeetingEvent])] {
        let grouped = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            (day: day, events: (grouped[day] ?? []).sorted { $0.start < $1.start })
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
public struct CalendarEventDetailView: View {
    public let event: CalendarMeetingEvent
    public let sourceName: String
    public let recordingUnavailableReason: String?
    public let onRecord: () -> Void
    public let showsDateAndSource: Bool

    public init(event: CalendarMeetingEvent, sourceName: String, recordingUnavailableReason: String? = nil,
                showsDateAndSource: Bool = true, onRecord: @escaping () -> Void) {
        self.event = event; self.sourceName = sourceName
        self.recordingUnavailableReason = recordingUnavailableReason; self.onRecord = onRecord
        self.showsDateAndSource = showsDateAndSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(event.title).font(.title.weight(.bold)).textSelection(.enabled)
                if showsDateAndSource {
                    Text(event.start, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(event.start, format: .dateTime.hour().minute())
                    Text("–")
                    Text(event.end, format: .dateTime.hour().minute())
                    Text(TimeZone.current.abbreviation() ?? TimeZone.current.identifier).font(.caption)
                }.font(.callout).foregroundStyle(.secondary)
                if showsDateAndSource { Text(sourceName).font(.caption).foregroundStyle(.secondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { eventActions }
                VStack(alignment: .leading, spacing: 10) { eventActions }
            }
            if let recordingUnavailableReason {
                Label(recordingUnavailableReason, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if event.attendees.isEmpty {
                Text("No invitees provided by this calendar.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Invited people").font(.headline)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, person in
                            HStack(spacing: 12) {
                                Text(String(person.displayName.prefix(1)).uppercased())
                                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                    .background(.quaternary, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(person.displayName + (person.isCurrentUser ? " (you)" : "")).font(.callout.weight(.medium))
                                    if let email = person.email { Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if person.isOrganizer { Text("Organizer").font(.caption).foregroundStyle(.secondary) }
                                    Text(invitationResponse(person.responseStatus)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("RSVPs describe invitation responses, not who attended. Confirm speakers from their voices after recording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func invitationResponse(_ response: String) -> String {
        switch response {
        case "accepted": return "RSVP: Accepted"
        case "declined": return "RSVP: Declined"
        case "tentative": return "RSVP: Tentative"
        case "needsAction", "pending": return "RSVP: Awaiting response"
        case "delegated": return "RSVP: Delegated"
        default: return "RSVP: Unknown"
        }
    }

    @ViewBuilder private var eventActions: some View {
        if let url = conferenceURL {
            Link(destination: url) {
                Label("Join call", systemImage: "video")
                    .font(.callout.weight(.medium)).padding(.horizontal, 18).frame(height: 42)
                    .minutesControlGlass(in: Capsule(), interactive: true)
            }.buttonStyle(.plain)
        }
        Button(action: onRecord) {
            Label("Record", systemImage: "record.circle")
                .font(.callout.weight(.medium)).padding(.horizontal, 18).frame(height: 42)
                .minutesControlGlass(in: Capsule(), interactive: true)
        }.buttonStyle(.plain).disabled(recordingUnavailableReason != nil || event.isCancelled)
        if event.isCancelled { Text("Cancelled").font(.caption).foregroundStyle(.secondary) }
    }

    private var conferenceURL: URL? {
        guard let raw = event.conferenceURL, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}
#endif
