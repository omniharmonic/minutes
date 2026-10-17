import AVFoundation
import Foundation

/// Measures real PCM samples; display units are a -60...0 dBFS scale, not amplitude percent.
enum CaptureLevelMeter {
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var energy: Double = 0
        var count = 0
        func accumulate<T>(_ data: UnsafeMutableRawPointer, count samples: Int, as type: T.Type, normalized: (T) -> Double) {
            let values = data.assumingMemoryBound(to: type)
            for index in 0..<samples {
                let value = normalized(values[index])
                if value.isFinite { energy += value * value }
            }
            count += samples
        }
        for channelBuffer in buffers {
            guard let data = channelBuffer.mData else { continue }
            let sampleCount = Int(buffer.frameLength) * Int(channelBuffer.mNumberChannels)
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                accumulate(data, count: min(sampleCount, Int(channelBuffer.mDataByteSize) / 4), as: Float.self) { Double($0) }
            case .pcmFormatFloat64:
                accumulate(data, count: min(sampleCount, Int(channelBuffer.mDataByteSize) / 8), as: Double.self) { $0 }
            case .pcmFormatInt16:
                accumulate(data, count: min(sampleCount, Int(channelBuffer.mDataByteSize) / 2), as: Int16.self) { Double($0) / 32768 }
            case .pcmFormatInt32:
                accumulate(data, count: min(sampleCount, Int(channelBuffer.mDataByteSize) / 4), as: Int32.self) { Double($0) / 2147483648 }
            default: break
            }
        }
        return count > 0 ? Float(sqrt(energy / Double(count))) : 0
    }

    static func displayLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }
}
