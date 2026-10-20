#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

public struct MeetingMarkdownDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.plainText] }
    public static var writableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }
    public var text: String
    public init(text: String = "") { self.text = text }
    public init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@available(macOS 15, iOS 18, *)
private struct MeetingMarkdownExporter: ViewModifier {
    @ObservedObject var state: AppState
    func body(content: Content) -> some View {
        content.fileExporter(isPresented: $state.markdownExportPresented,
            document: state.markdownExportDocument,
            contentType: MeetingMarkdownDocument.writableContentTypes[0],
            defaultFilename: state.markdownExportFilename) { result in
                switch result {
                case .success(let url):
                    state.statusMessage = "Markdown saved to \(url.path)."
                case .failure(let error):
                    state.statusMessage = "Markdown export failed: \(error.localizedDescription)"
                }
            }
    }
}

@available(macOS 15, iOS 18, *)
public extension View {
    func meetingMarkdownExporter(state: AppState) -> some View {
        modifier(MeetingMarkdownExporter(state: state))
    }
}
#endif
#if canImport(SwiftUI)
import CoreTransferable
import MinutesExport
import MinutesCore

/// What the system share sheet sends: the meeting as a Markdown file. It is
/// rendered only when the person picks a destination, not on every redraw.
@available(macOS 15, iOS 18, *)
public struct MeetingShareFile: Transferable, Sendable {
    public let filename: String
    let meetingID: String
    let store: MinutesStore

    func markdown() -> String {
        guard let meeting = store.getMeeting(id: meetingID) else { return "" }
        let clusters = store.listSpeakerClusters(meetingId: meetingID)
        let bundle = MeetingExportBundle(meeting: meeting, attendees: store.listPeopleForMeeting(meetingId: meetingID), clusters: clusters,
            utterances: TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meetingID), clusters: clusters),
            summary: store.getSummary(meetingId: meetingID))
        return MarkdownAdapter.render(bundle: bundle)
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: MeetingMarkdownDocument.writableContentTypes[0]) { file in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-share-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.filename)
            try Data(file.markdown().utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .plainText) { Data($0.markdown().utf8) }
    }
}

@available(macOS 15, iOS 18, *)
public extension AppState {
    /// The selected meeting, ready for the share sheet.
    var currentShareFile: MeetingShareFile? {
        guard let meeting = currentMeeting else { return nil }
        let title = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r")).joined(separator: "-")
        return MeetingShareFile(filename: String(title.prefix(120)) + ".md", meetingID: meeting.id, store: store)
    }
}
#endif
