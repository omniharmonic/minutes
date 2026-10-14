import Foundation
import AVFoundation

public final class AudioCaptureService: @unchecked Sendable {
    public static let shared = AudioCaptureService()
    
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var isCapturing = false
    private let lock = NSLock()
    
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    #endif
    
    public private(set) var currentLevel: Float = 0.0
    public private(set) var recordedDuration: Double = 0.0
    private var sampleCount: Int64 = 0
    private var targetSampleRate: Double = 16000.0
    
    private init() {}
    
    public func startRecording(to outputURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        
        if isCapturing {
            return
        }
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self,
                  let userInfo = notif.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            
            if type == .began {
                self.engine.pause()
            } else if type == .ended {
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        try? self.engine.start()
                    }
                }
            }
        }
        #endif
        
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        
        // Output format: 16kHz mono PCM for standard speech pipeline compatibility
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "AudioCaptureService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target 16kHz PCM audio format"]
            )
        }
        
        let dir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        self.audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: recordFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        
        self.targetSampleRate = 16000.0
        self.sampleCount = 0
        self.recordedDuration = 0.0
        
        guard let converter = AVAudioConverter(from: hwFormat, to: recordFormat) else {
            throw NSError(
                domain: "AudioCaptureService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter from \(hwFormat) to \(recordFormat)"]
            )
        }
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            
            // Calculate buffer RMS power for live audio meter
            var sum: Float = 0.0
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                for c in 0..<channelCount {
                    let ptr = channelData[c]
                    for f in 0..<frameLength {
                        let sample = ptr[f]
                        sum += sample * sample
                    }
                }
                let count = Float(frameLength * channelCount)
                let rms = count > 0 ? sqrt(sum / count) : 0.0
                self.currentLevel = rms
            }
            
            // Convert to 16kHz mono
            let ratio = 16000.0 / hwFormat.sampleRate
            let targetFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: targetFrameCapacity) else {
                return
            }
            
            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status != .error, convertedBuffer.frameLength > 0 {
                self.lock.lock()
                defer { self.lock.unlock() }
                if let file = self.audioFile {
                    try? file.write(from: convertedBuffer)
                    self.sampleCount += Int64(convertedBuffer.frameLength)
                    self.recordedDuration = Double(self.sampleCount) / 16000.0
                }
            }
        }
        
        engine.prepare()
        try engine.start()
        isCapturing = true
    }
    
    public func stopRecording() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        
        guard isCapturing else { return nil }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        
        #if os(iOS)
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        let url = audioFile?.url
        audioFile = nil
        isCapturing = false
        currentLevel = 0.0
        return url
    }
    
    public var capturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCapturing
    }
}
