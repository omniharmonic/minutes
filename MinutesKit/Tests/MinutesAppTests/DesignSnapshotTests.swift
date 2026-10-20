#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import Testing
import MinutesCore
import MinutesUI

/// Renders key surfaces to PNG for design review. Opt-in: MINUTES_SNAPSHOTS=<directory>.
@MainActor struct DesignSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_SNAPSHOTS"] != nil))
    func renderMeetingPage() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MINUTES_SNAPSHOTS"]!)
        let meeting = Meeting(id: "m", title: "Product tactical", userNotes: "Follow up with Priya on the launch plan.", audioPath: "/nonexistent/fixture.m4a")
        let lines = ["We agreed to move the beacon launch to May.", "Priya will draft the launch plan by Friday.", "Do we need separate newsletters per city?", "Let's revisit the budget next week."]
        let utterances = lines.enumerated().map { Utterance(id: $0.offset + 1, meetingId: "m", clusterId: "c\($0.offset % 2)", speakerName: $0.offset % 2 == 0 ? "Ana" : "Priya", start: Double($0.offset) * 312 + 4, end: Double($0.offset) * 312 + 40, text: $0.element) }
        let summary = MeetingSummary(meetingId: "m", title: meeting.title, overview: "", markdown: "### Overview\nThe team moved the launch and assigned the plan. [T0001]\n\n### Decisions\n- Launch moves to May [T0001]\n\n### Action items\n- Priya drafts the launch plan [T0002]\n- Revisit the budget [T0004, T0003]")
        let marks = [Bookmark(meetingId: "m", timestamp: 318, label: "Launch date"), Bookmark(meetingId: "m", timestamp: 940, label: "Budget")]
        for (name, width, scheme) in [("notes-wide-light", 1100.0, ColorScheme.light), ("notes-wide-dark", 1100.0, .dark), ("notes-narrow", 520.0, .light)] {
            let view = NotesView(meeting: meeting, summary: summary, utterances: utterances, attendees: [], bookmarks: marks,
                                 onSaveNotes: { _ in }, onSaveBookmark: { _ in }, onDeleteBookmark: { _ in }, onGenerateSummary: {},
                                 onExportMarkdown: {}, onExportParachute: {}, onSaveSummary: { _ in })
                .padding(28).frame(width: width).background(MinutesTheme.document).environment(\.colorScheme, scheme)
            try write(view, to: directory.appendingPathComponent(name + ".png"))
        }
        let toggles = VStack(spacing: 18) {
            Toggle("Save each meeting automatically", isOn: .constant(true))
            Divider()
            Toggle("Automatically file new meetings", isOn: .constant(false))
        }.toggleStyle(MinutesToggleStyle()).padding(20).frame(width: 420).background(MinutesTheme.card)
        try write(toggles, to: directory.appendingPathComponent("toggles.png"))
        let record = HStack(spacing: 40) {
            RecordingLaunchButton(isRecording: false, duration: 0, style: .circle) {}
            RecordingLaunchButton(isRecording: true, duration: 754, style: .circle) {}
        }.padding(30).frame(width: 300).background(LinearGradient(colors: [.orange, .purple], startPoint: .top, endPoint: .bottom))
        try write(record, to: directory.appendingPathComponent("record.png"))
    }

    private func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
#endif
