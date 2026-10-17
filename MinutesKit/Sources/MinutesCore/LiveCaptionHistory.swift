import Foundation

/// Disposable preview history. A recognizer revises one segment until it closes.
public struct LiveCaptionHistory: Sendable {
    public struct Line: Identifiable, Sendable, Equatable {
        public let id: String
        public var text: String
        public let source: String
        public var isFinal: Bool
        public var speakerName: String? = nil
    }
    public private(set) var lines: [Line] = []
    public let limit: Int
    public init(limit: Int = 200) { self.limit = max(1, limit) }
    public mutating func update(id: String, text: String, source: String, isFinal: Bool) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !text.isEmpty else { return }
        if let index = lines.firstIndex(where: { $0.id == id }) {
            guard !lines[index].isFinal else { return }
            lines[index].text = text; lines[index].isFinal = isFinal
        } else {
            lines.append(Line(id: id, text: text, source: source, isFinal: isFinal))
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }
    public mutating func identify(id: String, name: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].speakerName = name
    }
    public mutating func finish() {
        for index in lines.indices { lines[index].isFinal = true }
    }
}
