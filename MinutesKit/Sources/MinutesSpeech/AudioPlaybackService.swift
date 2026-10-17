import Foundation
import AVFoundation
import Combine

@MainActor
public final class AudioPlaybackService: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    public static let shared = AudioPlaybackService()
    
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: Double = 0.0
    @Published public private(set) var duration: Double = 0.0
    @Published public private(set) var currentAudioPath: String? = nil
    
    private var player: AVAudioPlayer?
    private var timeObserver: Timer?
    private var stopTime: Double? = nil
    
    public override init() {
        super.init()
    }
    
    public func loadAudio(path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "AudioPlaybackService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Audio file not found at: \(path)"])
        }
        
        stop()
        let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        self.player = audioPlayer
        self.currentAudioPath = path
        self.duration = audioPlayer.duration
        self.currentTime = 0.0
    }
    
    @discardableResult public func play(from startTime: Double = 0.0, to endTime: Double? = nil) -> Bool {
        guard let p = player else { return false }
        #if os(iOS)
        // Recording deactivates its session at Stop. Restore the media route
        // only for an explicit Play action, including resumed samples.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            self.isPlaying = false
            return false
        }
        #endif
        p.currentTime = max(0.0, min(startTime, p.duration))
        self.currentTime = p.currentTime
        self.stopTime = endTime
        
        guard p.play() else { self.isPlaying = false; return false }
        self.isPlaying = true
        startTimeObserver()
        return true
    }
    
    public func pause() {
        player?.pause()
        self.isPlaying = false
        stopTimeObserver()
    }
    
    public func stop() {
        player?.stop()
        self.isPlaying = false
        self.stopTime = nil
        stopTimeObserver()
    }
    
    public func seek(to time: Double) {
        guard let p = player else { return }
        p.currentTime = max(0.0, min(time, p.duration))
        self.currentTime = p.currentTime
    }
    
    private func startTimeObserver() {
        stopTimeObserver()
        timeObserver = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if let stop = self.stopTime, p.currentTime >= stop {
                    self.pause()
                    self.stopTime = nil
                }
            }
        }
    }
    
    private func stopTimeObserver() {
        timeObserver?.invalidate()
        timeObserver = nil
    }
    
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTime = nil
            self.stopTimeObserver()
            self.currentTime = self.duration
        }
    }
}
