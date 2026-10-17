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
