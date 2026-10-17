#if os(macOS)
import AppKit
import SwiftUI
import MinutesCore
import MinutesSpeech
import MinutesUI

@MainActor final class CaptionPanelModel: ObservableObject {
    @Published var history = LiveCaptionHistory()
    @Published var status = "Start a recording in Minutes to see live captions."
    @Published var expanded = true
    @Published var following = true
    @Published var recording = false
    @Published var demo = false
}

private final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CaptionPanelController {
    let model = CaptionPanelModel()
    var savedVoices: () -> ([Person], [Voiceprint]) = { ([], []) }
    private let voiceMatcher = LiveVoiceMatcher()
    private var pendingNames: [String: String] = [:]
    private var identityTask: Task<Void, Never>?
    private var identityQueue = LiveVoiceWindowQueue()
    private var panel: CaptionPanel?
    private let recognizer = LiveCaptionRecognizer()
    private var demoTask: Task<Void, Never>?
    private var enabled = false
    private var generation = UUID()
    private var screenObserver: NSObjectProtocol?

    func show(recording: Bool) {
        enabled = true
        present()
        if recording && !model.recording { begin() }
    }
    func begin() {
        guard enabled else { return }
        generation = UUID(); identityTask?.cancel(); identityTask = nil; demoTask?.cancel(); model.demo = false
        pendingNames.removeAll(); identityQueue.removeAll()
        model.history = LiveCaptionHistory(); model.recording = true; model.following = true
        model.status = "Listening locally · preview may change"
        do {
            let (_, voices) = savedVoices()
            let token = generation
            let identify: LiveCaptionRecognizer.AudioWindow = { [weak self] id, samples, rate in
                guard let self else { return }
                guard self.identityQueue.append(.init(id: id, samples: samples, rate: rate)) else {
                    self.model.status = "Voice matching is catching up · some captions may stay unnamed"
                    return
                }
                guard self.identityTask == nil else { return }
                self.identityTask = Task { [weak self] in
                    guard let self else { return }
                    defer { if self.generation == token { self.identityTask = nil } }
                    while !Task.isCancelled, self.generation == token,
                          let window = self.identityQueue.next() {
                        do {
                            // Re-read consented profiles: forget/remember actions apply to pending work.
                            let (currentPeople, currentVoices) = self.savedVoices()
                            let result = try await self.voiceMatcher.evaluate(samples: window.samples, rate: window.rate,
                                people: currentPeople, voiceprints: currentVoices)
                            guard !Task.isCancelled, self.generation == token else { return }
                            // Never apply an identity removed while inference was running.
                            let (latestPeople, latestVoices) = self.savedVoices()
                            guard let personID = result.personID,
                                  let name = latestPeople.first(where: { $0.id == personID })?.displayName,
                                  currentVoices.filter({ $0.personId == personID }).map(\.id).sorted() == latestVoices.filter({ $0.personId == personID }).map(\.id).sorted() else { continue }
                            if self.pendingNames.count >= 200 { self.pendingNames.removeAll() }
                            self.pendingNames[window.id] = name
                            self.model.history.identify(id: window.id, name: name)
                        } catch {
                            guard !Task.isCancelled, self.generation == token else { return }
                            self.model.status = "Live voice matching unavailable · captions and recording continue"
                        }
                    }
                }
            }
            try recognizer.start(audioWindow: voices.isEmpty ? nil : identify, update: { [weak self] id, text, source, final, order in
                guard let self else { return }
                self.model.history.update(id: id, text: text, source: source, isFinal: final, order: order)
                if let name = self.pendingNames[id] { self.model.history.identify(id: id, name: name) }
            }, notice: { [weak self] message in if self?.model.recording == true { self?.model.status = message } })
        } catch { model.recording = false; model.status = "Captions unavailable: \(error.localizedDescription)" }
        present()
    }
    func finish() {
        demoTask?.cancel(); demoTask = nil
        let token = generation
        model.recording = false
        Task { [weak self] in
            guard let self else { return }
            await self.recognizer.finish()
            await self.identityTask?.value
            guard self.generation == token else { return }
            self.model.history.finish()
        }
        model.status = "Recording ended · final transcript is in Minutes"
    }
    func close() {
        generation = UUID(); identityTask?.cancel(); identityTask = nil; identityQueue.removeAll(); enabled = false; demoTask?.cancel(); demoTask = nil; recognizer.stop()
        model.recording = false; panel?.orderOut(nil)
    }
    func focus() { present(); panel?.makeKeyAndOrderFront(nil) }
    func previewFile(_ url: URL) {
        guard !model.recording else { return }
        enabled = true; begin()
        guard model.recording else { panel?.makeKeyAndOrderFront(nil); return }
        model.demo = true
        panel?.makeKeyAndOrderFront(nil)
        model.status = "Silent file preview · no microphone or playback"
        let token = generation
        demoTask = Task { [weak self] in
            do { try await CaptionFileFixture.feed(url: url) }
            catch {
                guard let self, self.generation == token else { return }
                self.model.status = "File preview ended: \(error.localizedDescription)"
            }
            guard let self, self.generation == token else { return }
            await self.recognizer.finish()
            await self.identityTask?.value
            guard self.generation == token else { return }
            self.model.recording = false; self.model.history.finish()
            self.model.status = self.model.history.lines.isEmpty ? "No preview text received · check local Speech availability" : "File preview complete · \(self.recognizer.diagnostics.sessionsStarted) recognition sessions · \(self.recognizer.diagnostics.recognitionRetries) retries · \(self.recognizer.diagnostics.droppedBatches) dropped batches"
        }
    }
    func preview() {
        guard !model.recording else { return }
        generation = UUID(); recognizer.stop(); demoTask?.cancel(); enabled = false
        model.history = LiveCaptionHistory(); model.demo = true; model.following = true
        model.status = "Silent design preview · no audio capture"
        present(); panel?.makeKeyAndOrderFront(nil)
        demoTask = Task { [weak self] in
            let phrases = [
                "Welcome to your reverse teleprompter. Keep your eyes near the camera while the conversation unfolds.",
                "This is synthetic text. No microphone is open and nothing is playing.",
                "Scroll back whenever you need a moment to catch up. New phrases will wait below.",
                "Choose Live to follow the conversation again. Your saved transcript remains separate.",
                "The panel can move to another display, or collapse into a quiet strip below the camera.",
                "Live captions are a preview. Speaker names will arrive only when voice matching is reliable."]
            for index in 0..<18 {
                let phrase = phrases[index % phrases.count], words = phrase.split(separator: " ")
                for length in stride(from: 3, through: words.count + 2, by: 3) {
                    guard !Task.isCancelled, let self else { return }
                    let n = min(length, words.count)
                    self.model.history.update(id: "demo-\(index)", text: words.prefix(n).joined(separator: " "), source: "Preview", isFinal: n == words.count)
                    try? await Task.sleep(for: .milliseconds(220))
                }
            }
            self?.model.status = "Preview complete · scroll to review"
        }
    }
    private func present() {
        if panel == nil {
            let window = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 370),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Minutes Live Captions"
            window.isExcludedFromWindowsMenu = false
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.level = .floating; window.isFloatingPanel = true; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CaptionPanelView(model: model,
                close: { [weak self] in self?.close() }, resize: { [weak self] in self?.resize() },
                move: { [weak self] screen in self?.anchor(to: screen) }))
            panel = window
            anchor(to: NSApp.mainWindow?.screen ?? NSScreen.main)
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.anchor(to: self?.panel?.screen ?? NSScreen.main) }
            }
        }
        panel?.orderFrontRegardless()
    }
    private func resize() {
        guard let panel else { return }
        let height: CGFloat = model.expanded ? 370 : 126
        var frame = panel.frame; frame.origin.y += frame.height - height; frame.size.height = height
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func anchor(to screen: NSScreen?) {
        guard let panel, let screen else { return }
        let width = min(CGFloat(620), screen.visibleFrame.width - 32)
        let top = min(screen.frame.maxY - screen.safeAreaInsets.top, screen.visibleFrame.maxY) - 8
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: top - panel.frame.height,
                              width: width, height: panel.frame.height), display: true)
    }
}

private struct CaptionPanelView: View {
    @ObservedObject var model: CaptionPanelModel
    let close: () -> Void
    let resize: () -> Void
    let move: (NSScreen) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 12) {
                    content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: model.expanded ? 28 : 32))
                        .glassEffectID("caption-panel", in: glass)
                }
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            }
        }
        .padding(8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.expanded)
        .onExitCommand { model.expanded = false; resize() }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                Text(model.demo ? "Caption Preview" : "Live Captions").font(.subheadline.weight(.semibold))
                Spacer()
                if !model.following {
                    Button { model.following = true } label: { Label("Live", systemImage: "arrow.down") }
                        .buttonStyle(.borderless).help("Return to the latest caption")
                }
                Menu {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        Button(screen.localizedName) { move(screen) }
                    }
                } label: { Image(systemName: "display") }
                    .menuStyle(.borderlessButton).fixedSize().help("Move captions to a display")
                Button { model.expanded.toggle(); resize() } label: {
                    Image(systemName: model.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.accessibilityLabel(model.expanded ? "Collapse captions" : "Expand caption history")
                    .help(model.expanded ? "Collapse captions" : "Expand caption history")
                Button(action: close) { Image(systemName: "xmark") }.help("Close captions without stopping recording")
            }
            .buttonStyle(.plain)
            if model.expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if model.history.lines.isEmpty {
                                Text(model.recording ? "Waiting for speech…" : "Your conversation, closer to the camera.")
                                    .font(.title3).foregroundStyle(.secondary).padding(.vertical, 24)
                            }
                            ForEach(model.history.lines) { line in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(line.speakerName.map { "\($0) · likely · \(line.source)" } ?? line.source).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    Text(line.text).font(.system(size: 20, weight: .medium)).lineSpacing(5)
                                        .foregroundStyle(line.isFinal ? .primary : .secondary)
                                        .textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(.trailing, 8)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting || phase == .tracking { model.following = false }
                    }
                    .onChange(of: model.history.lines) { _, _ in
                        if model.following { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onChange(of: model.following) { _, follow in
                        if follow { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onAppear { if model.following { proxy.scrollTo("latest", anchor: .bottom) } }
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(model.history.lines.last?.text ?? model.status)
                    .font(.system(size: 17, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
