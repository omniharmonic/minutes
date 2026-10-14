import Foundation
import AVFoundation

public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let duration: Double
    public let channelCount: Int
    
    public init(samples: [Float], sampleRate: Double, duration: Double, channelCount: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.channelCount = channelCount
    }
}

public enum AudioDecodeError: Error, LocalizedError {
    case fileNotFound(URL)
    case fileEmpty(URL)
    case unsupportedFormat(String)
    case conversionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Audio file not found at path: \(url.path)"
        case .fileEmpty(let url):
            return "Audio file is empty (0 bytes) at path: \(url.path)"
        case .unsupportedFormat(let msg):
            return "Unsupported audio format: \(msg)"
        case .conversionFailed(let msg):
            return "Audio conversion failed: \(msg)"
        }
    }
}

public enum AudioDecoder {
    /// Decodes an audio file at the given URL into normalized 16kHz mono float32 PCM samples.
    public static func decode(fileURL: URL, targetSampleRate: Double = 16000.0) throws -> DecodedAudio {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AudioDecodeError.fileNotFound(fileURL)
        }
        
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            throw AudioDecodeError.fileEmpty(fileURL)
        }
        
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioDecodeError.unsupportedFormat(error.localizedDescription)
        }
        
        let sourceFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            throw AudioDecodeError.fileEmpty(fileURL)
        }
        
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioDecodeError.conversionFailed("Unable to create target 16kHz mono format")
        }
        
        // If already 16kHz mono float32, read directly
        if sourceFormat.sampleRate == targetSampleRate && sourceFormat.channelCount == 1 && sourceFormat.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                throw AudioDecodeError.conversionFailed("Unable to allocate PCM buffer")
            }
            try audioFile.read(into: buffer)
            let floatData = buffer.floatChannelData![0]
            let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(buffer.frameLength)))
            let duration = Double(samples.count) / targetSampleRate
            return DecodedAudio(samples: samples, sampleRate: targetSampleRate, duration: duration)
        }
        
        // Otherwise, read into source buffer then convert
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioDecodeError.conversionFailed("Unable to allocate source buffer")
        }
        try audioFile.read(into: sourceBuffer)
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioDecodeError.conversionFailed("Cannot create audio converter from \(sourceFormat) to \(targetFormat)")
        }
        
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 1024)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw AudioDecodeError.conversionFailed("Unable to allocate target buffer")
        }
        
        var error: NSError?
        var hasProvidedData = false
        converter.convert(to: targetBuffer, error: &error) { inNumPackets, outStatus in
            if !hasProvidedData {
                hasProvidedData = true
                outStatus.pointee = .haveData
                return sourceBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let err = error {
            throw AudioDecodeError.conversionFailed(err.localizedDescription)
        }
        
        guard let floatData = targetBuffer.floatChannelData else {
            throw AudioDecodeError.conversionFailed("Target buffer channel data is nil")
        }
        
        let sampleCount = Int(targetBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: sampleCount))
        let duration = Double(samples.count) / targetSampleRate
        
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate, duration: duration)
    }
}
