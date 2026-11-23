import Foundation
import MinutesControl

// stdio MCP server: newline-delimited JSON-RPC on stdin/stdout, relayed to the
// Minutes control socket. Diagnostics go to stderr only; stdout carries protocol.
setvbuf(stdout, nil, _IOFBF, 1 << 16)
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
let server = MCPServer(version: version, client: ControlSocketClient())

func emit(_ data: Data) {
    FileHandle.standardOutput.write(data)
}

// Requests are answered in order; a slow stop holds later calls until it returns.
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }
    let done = DispatchSemaphore(value: 0)
    // Detached: top-level code is main-actor isolated and the main thread waits below.
    Task.detached {
        if let reply = await server.handle(line: Data(trimmed.utf8)) { emit(reply) }
        done.signal()
    }
    done.wait()
}
