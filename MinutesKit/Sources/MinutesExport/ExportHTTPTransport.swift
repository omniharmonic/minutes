import Foundation

// Never forward a bearer token through an HTTP redirect or a cleartext remote origin.
enum ExportHTTPTransport {
    static func validateOrigin(_ url:URL?) throws {
        guard let url, let host=url.host, url.user==nil, url.password==nil, url.query==nil, url.fragment==nil,
              url.scheme=="https" || (url.scheme=="http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host)) else {throw LegacyExportError.invalidDestination}
    }
    static func makeSession() -> URLSession {URLSession(configuration:.ephemeral,delegate:RejectExportRedirects(),delegateQueue:nil)}
}
private final class RejectExportRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void){completionHandler(nil)}
}
