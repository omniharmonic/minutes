import Foundation
import Testing
import MinutesCore
import MinutesExport

private final class LegacyFailureProtocol: URLProtocol, @unchecked Sendable {
 override class func canInit(with request:URLRequest)->Bool {request.url?.host=="minutes.invalid"}
 override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
 override func startLoading(){
  let status=request.httpMethod=="PATCH" ? 500 : 201
  let data=Data("{\"id\":\"test_note\"}".utf8)
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}

@Suite("Credential and legacy export transport safety")
struct TransportSafetyTests {
 @Test("Legacy vault link failure cannot return successful export")
 func failedLinkIsFailure() async throws {
  let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[LegacyFailureProtocol.self]
  let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
  let adapter=ParachuteAdapter(vaultHost:"https://minutes.invalid",tokenProvider:{"fixture-token"},session:session)
  let meeting=Meeting(id:"meeting",title:"Meeting")
  let bundle=MeetingExportBundle(meeting:meeting,attendees:[Person(id:"person",displayName:"Person")],clusters:[],utterances:[],summary:nil)
  do { _=try await adapter.export(bundle:bundle);Issue.record("HTTP500 was reported as export success") }
  catch LegacyExportError.httpStatus(500) {} catch {Issue.record("Wrong failure: \(error)")}
 }
 @Test("Legacy export refuses cleartext remote credentials before a request")
 func remoteHTTPIsRejected() async throws {
  let adapter=ParachuteAdapter(vaultHost:"http://minutes.invalid",tokenProvider:{"fixture-token"})
  let bundle=MeetingExportBundle(meeting:Meeting(title:"Meeting"),attendees:[],clusters:[],utterances:[],summary:nil)
  do {_=try await adapter.export(bundle:bundle);Issue.record("Remote HTTP accepted")}
  catch LegacyExportError.invalidDestination {} catch {Issue.record("Wrong failure: \(error)")}
 }
 @Test("Prism refuses cleartext origin and path traversal in meeting identifiers")
 func prismOriginAndPath() async throws {
  let meeting=Meeting(id:"../../admin",title:"Meeting")
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:directory)}
  let store=try MinutesStore(dbPath:directory.appendingPathComponent("db").path)
  try store.saveMeeting(meeting)
  let client=PrismClient(baseURL:URL(string:"http://minutes.invalid")!,tokenProvider:{"fixture-token"})
  let item=try OutboxManager(store:store,client:client).enqueue(bundle:MeetingExportBundle(meeting:meeting,attendees:[],clusters:[],utterances:[],summary:nil),destinationVault:"fixture")
  let payload=try JSONDecoder().decode(PrismMeetingPayload.self,from:Data(item.payloadJson.utf8))
  for url in ["http://minutes.invalid","https://minutes.invalid"] {
   do {_=try await PrismClient(baseURL:URL(string:url)!,tokenProvider:{"fixture-token"}).uploadMeeting(payload:payload,destinationVault:"fixture",idempotencyKey:"fixture",baseRevision:nil);Issue.record("Unsafe origin/path was accepted")}
   catch PrismError.invalidPayload {} catch {Issue.record("Wrong failure: \(error)")}
  }
 }
}
