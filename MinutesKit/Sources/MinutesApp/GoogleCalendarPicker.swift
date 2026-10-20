#if canImport(SwiftUI)
import SwiftUI
import MinutesCalendar

/// Choose which Google calendars appear in Upcoming, by name.
@available(macOS 15.0, iOS 18.0, *)
public struct GoogleCalendarPicker: View {
    @ObservedObject var appState: AppState
    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        Group {
            if appState.googleConnected {
                if appState.googleCalendarChoices.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading your calendars…").foregroundStyle(.secondary) }
                }
                ForEach(appState.googleCalendarChoices) { calendar in
                    Toggle(isOn: Binding(get: { appState.isGoogleCalendarSelected(calendar) },
                                         set: { appState.setGoogleCalendar(calendar, included: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.summary ?? calendar.id)
                            if calendar.primary == true { Text("Your main calendar").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .task(id: appState.googleConnected) { if appState.googleConnected { await appState.loadGoogleCalendarChoices() } }
    }
}
#endif
