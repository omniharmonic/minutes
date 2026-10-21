#if canImport(SwiftUI)
import SwiftUI
import MinutesCore

/// Scrolling, follow-the-latest live caption list for the recording screen.
/// Scrolling back pauses following; "Latest" resumes it.
@available(macOS 15.0, iOS 18.0, *)
public struct LiveCaptionScrollView: View {
    public let history: LiveCaptionHistory
    public let status: String
    public let isListening: Bool
    @State private var following = true

    public init(history: LiveCaptionHistory, status: String, isListening: Bool) {
        self.history = history; self.status = status; self.isListening = isListening
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Live Captions", systemImage: "captions.bubble").font(.subheadline.weight(.semibold))
                Spacer()
                if !following {
                    Button { following = true } label: { Label("Latest", systemImage: "arrow.down") }
                        .font(.caption.weight(.medium)).buttonStyle(.borderless)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if history.lines.isEmpty {
                            Text(isListening ? "Waiting for speech…" : "No captions yet.")
                                .foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(history.lines) { line in
                            Text(line.text).font(.body.weight(.medium))
                                .foregroundStyle(line.isFinal ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { following = false }
                }
                .onChange(of: history.lines) { _, _ in
                    if following { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: following) { _, follow in
                    if follow { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Preview only · on this device · separate from the saved transcript")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .minutesControlGlass(in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}
#endif
