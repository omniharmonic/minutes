import Foundation

/// CLI parsing is kept separate from permission requests and audio device access.
public struct SystemCaptureOptions: Sendable {
    public let directory: URL
    public let seconds: Double
    public let includeMicrophone: Bool
    public let requestPermission: Bool
    public init(arguments: [String]) throws {
        var path: String?
        var duration: Double?
        var microphone = true
        var request = false
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw Self.invalid("Duplicate option: \(option)") }
            switch option {
            case "--output-dir", "--seconds":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw Self.invalid("Missing value for \(option)") }
                if option == "--output-dir" { path = arguments[index] }
                else { duration = Double(arguments[index]) }
            case "--system-only": microphone = false
            case "--request-permission": request = true
            default: throw Self.invalid("Unknown capture option: \(option)")
            }
            index += 1
        }
        guard let path, !path.isEmpty, let duration, duration.isFinite, duration >= 0.1, duration <= 86_400 else {
            throw Self.invalid("Usage: capture-system --output-dir <new-directory> --seconds <0.1...86400> [--system-only] [--request-permission]")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        seconds = duration
        includeMicrophone = microphone
        requestPermission = request
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "Minutes.SystemCapture.Options", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
