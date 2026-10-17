import Foundation
import Testing
import MinutesCore
import MinutesExport

@Suite("Markdown export data safety")
struct MarkdownSafetyTests {
 @Test("Same-title meetings keep separate files, renames update stable identity, and personal notes survive")
 func identityAndNotes() async throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:directory)}
  let adapter=MarkdownAdapter(outputDirectory:directory.path)
  var one=Meeting(id:"one",title:"Daily sync",userNotes:"My private annotations")
  let two=Meeting(id:"two",title:"Daily sync")
  func bundle(_ m:Meeting)->MeetingExportBundle{MeetingExportBundle(meeting:m,attendees:[],clusters:[],utterances:[],summary:nil)}
  let first=try await adapter.export(bundle:bundle(one)),second=try await adapter.export(bundle:bundle(two))
  #expect(first.pathOrURL != second.pathOrURL)
  let firstContents=try String(contentsOfFile:first.pathOrURL!,encoding:.utf8)
  #expect(firstContents.contains("My private annotations"))
  one.title="A renamed meeting"
  let renamed=try await adapter.export(bundle:bundle(one))
  #expect(renamed.pathOrURL==first.pathOrURL)
 }
 @Test("YAML title quoting survives embedded quotes and newlines")
 func frontMatterEscapes() async throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:directory)}
  let meeting=Meeting(id:"quote",title:"Review \"A\"\nstatus: changed")
  let result=try await MarkdownAdapter(outputDirectory:directory.path).export(bundle:MeetingExportBundle(meeting:meeting,attendees:[],clusters:[],utterances:[],summary:nil))
  let contents=try String(contentsOfFile:result.pathOrURL!,encoding:.utf8)
  #expect(contents.contains("title: \"Review \\\"A\\\"\\nstatus: changed\""))
 }
}
