import Foundation
import Accelerate

public enum EmbeddingService {
    public static let embeddingDimension = 256
    
    /// Extracts a normalized 256-dimensional acoustic MFCC/spectral embedding from audio samples.
    public static func extractEmbedding(samples: [Float], sampleRate: Double = 16000.0) -> [Float] {
        guard samples.count >= 160 else {
            return [Float](repeating: 0.0, count: embeddingDimension)
        }
        
        let frameSize = 512
        let hopSize = 160 // 10ms at 16kHz
        guard samples.count >= frameSize else {
            // Pad samples to frameSize
            var padded = samples
            padded.append(contentsOf: [Float](repeating: 0.0, count: frameSize - samples.count))
            return extractEmbedding(samples: padded, sampleRate: sampleRate)
        }
        
        let log2n = vDSP_Length(9) // 2^9 = 512
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0.0, count: embeddingDimension)
        }
        defer { vDSP_destroy_fftsetup(setup) }
        
        // Hamming window
        var hamming = [Float](repeating: 0.0, count: frameSize)
        for i in 0..<frameSize {
            hamming[i] = 0.54 - 0.46 * cos(2.0 * .pi * Float(i) / Float(frameSize - 1))
        }
        
        let numBands = 32
        var frameMFCCs = [[Float]]()
        var spectralCentroids = [Float]()
        var spectralRollOffs = [Float]()
        var zeroCrossingRates = [Float]()
        var frameEnergies = [Float]()
        
        var offset = 0
        while offset + frameSize <= samples.count {
            var real = [Float](repeating: 0.0, count: frameSize / 2)
            var imag = [Float](repeating: 0.0, count: frameSize / 2)
            var zcrCount = 0
            var sumSquare: Float = 0.0
            
            for i in 0..<(frameSize / 2) {
                let s0 = samples[offset + 2 * i]
                let s1 = samples[offset + 2 * i + 1]
                real[i] = s0 * hamming[2 * i]
                imag[i] = s1 * hamming[2 * i + 1]
                sumSquare += s0 * s0 + s1 * s1
                
                if i > 0 {
                    let prev = samples[offset + 2 * i - 1]
                    if (s0 >= 0 && prev < 0) || (s0 < 0 && prev >= 0) { zcrCount += 1 }
                    if (s1 >= 0 && s0 < 0) || (s1 < 0 && s0 >= 0) { zcrCount += 1 }
                }
            }
            
            frameEnergies.append(sqrt(sumSquare / Float(frameSize)))
            zeroCrossingRates.append(Float(zcrCount) / Float(frameSize))
            
            var mags = [Float](repeating: 0.0, count: frameSize / 2)
            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(frameSize / 2))
                }
            }
            
            // Group 256 frequency bins into 32 bands
            var logBands = [Float](repeating: 0.0, count: numBands)
            var totalMag: Float = 0.0
            var weightedFreq: Float = 0.0
            
            for b in 0..<numBands {
                let start = b * 8
                let end = min(256, start + 8)
                var bandSum: Float = 0.0
                for k in start..<end {
                    let m = mags[k]
                    bandSum += m
                    let amp = sqrt(m)
                    totalMag += amp
                    weightedFreq += amp * Float(k)
                }
                logBands[b] = log(max(1e-6, bandSum / Float(end - start)))
            }
            
            let centroid = totalMag > 1e-6 ? (weightedFreq / totalMag) : 0.0
            spectralCentroids.append(centroid)
            
            // 85% spectral rolloff
            var cumAmp: Float = 0.0
            let targetRolloff = totalMag * 0.85
            var rollBin = 255
            for k in 0..<256 {
                cumAmp += sqrt(mags[k])
                if cumAmp >= targetRolloff {
                    rollBin = k
                    break
                }
            }
            spectralRollOffs.append(Float(rollBin) / 256.0)
            
            // Compute 31 MFCCs (skip c0 to remain invariant to overall volume)
            var mfccs = [Float](repeating: 0.0, count: 31)
            for k in 1...31 {
                var sum: Float = 0.0
                for n in 0..<numBands {
                    sum += logBands[n] * cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(numBands))
                }
                mfccs[k - 1] = sum
            }
            frameMFCCs.append(mfccs)
            
            offset += hopSize
        }
        
        let frameCount = frameMFCCs.count
        guard frameCount > 0 else {
            return [Float](repeating: 0.0, count: embeddingDimension)
        }
        
        var features = [Float]()
        features.reserveCapacity(embeddingDimension)
        
        // 1. Mean MFCC (31 dims)
        var meanMFCC = [Float](repeating: 0.0, count: 31)
        for m in 0..<31 {
            var sum: Float = 0.0
            for f in 0..<frameCount { sum += frameMFCCs[f][m] }
            let avg = sum / Float(frameCount)
            meanMFCC[m] = avg
            features.append(avg)
        }
        
        // 2. Std Dev MFCC (31 dims)
        for m in 0..<31 {
            let avg = meanMFCC[m]
            var sumVar: Float = 0.0
            for f in 0..<frameCount {
                let diff = frameMFCCs[f][m] - avg
                sumVar += diff * diff
            }
            features.append(sqrt(sumVar / Float(frameCount)))
        }
        
        // 3. Delta MFCC mean (31 dims)
        var deltaMFCCs = [[Float]]()
        if frameCount > 1 {
            for f in 1..<frameCount {
                var deltas = [Float](repeating: 0.0, count: 31)
                for m in 0..<31 {
                    deltas[m] = frameMFCCs[f][m] - frameMFCCs[f - 1][m]
                }
                deltaMFCCs.append(deltas)
            }
        } else {
            deltaMFCCs.append([Float](repeating: 0.0, count: 31))
        }
        
        var meanDelta = [Float](repeating: 0.0, count: 31)
        for m in 0..<31 {
            var sum: Float = 0.0
            for d in deltaMFCCs { sum += d[m] }
            let avg = sum / Float(deltaMFCCs.count)
            meanDelta[m] = avg
            features.append(avg)
        }
        
        // 4. Delta MFCC std dev (31 dims)
        for m in 0..<31 {
            let avg = meanDelta[m]
            var sumVar: Float = 0.0
            for d in deltaMFCCs {
                let diff = d[m] - avg
                sumVar += diff * diff
            }
            features.append(sqrt(sumVar / Float(deltaMFCCs.count)))
        }
        
        // 5. Delta-Delta MFCC mean (31 dims)
        var delta2MFCCs = [[Float]]()
        if deltaMFCCs.count > 1 {
            for f in 1..<deltaMFCCs.count {
                var d2 = [Float](repeating: 0.0, count: 31)
                for m in 0..<31 { d2[m] = deltaMFCCs[f][m] - deltaMFCCs[f - 1][m] }
                delta2MFCCs.append(d2)
            }
        } else {
            delta2MFCCs.append([Float](repeating: 0.0, count: 31))
        }
        
        var meanDelta2 = [Float](repeating: 0.0, count: 31)
        for m in 0..<31 {
            var sum: Float = 0.0
            for d in delta2MFCCs { sum += d[m] }
            let avg = sum / Float(delta2MFCCs.count)
            meanDelta2[m] = avg
            features.append(avg)
        }
        
        // 6. Delta-Delta MFCC std dev (31 dims)
        for m in 0..<31 {
            let avg = meanDelta2[m]
            var sumVar: Float = 0.0
            for d in delta2MFCCs {
                let diff = d[m] - avg
                sumVar += diff * diff
            }
            features.append(sqrt(sumVar / Float(delta2MFCCs.count)))
        }
        
        // 7. Spectral Centroid progression (32 dims)
        let centStep = max(1, spectralCentroids.count / 32)
        for c in 0..<32 {
            let start = c * centStep
            let end = min(spectralCentroids.count, start + centStep)
            if start < end {
                let slice = spectralCentroids[start..<end]
                features.append(slice.reduce(0, +) / Float(slice.count))
            } else {
                features.append(spectralCentroids.last ?? 0.0)
            }
        }
        
        // 8. Spectral Rolloff progression (32 dims)
        let rollStep = max(1, spectralRollOffs.count / 32)
        for c in 0..<32 {
            let start = c * rollStep
            let end = min(spectralRollOffs.count, start + rollStep)
            if start < end {
                let slice = spectralRollOffs[start..<end]
                features.append(slice.reduce(0, +) / Float(slice.count))
            } else {
                features.append(spectralRollOffs.last ?? 0.0)
            }
        }
        
        // 9. Zero-Crossing Rate & RMS Frame Energy distribution (6 dims)
        for i in 0..<3 {
            let zStep = max(1, zeroCrossingRates.count / 3)
            let zStart = i * zStep
            let zEnd = min(zeroCrossingRates.count, zStart + zStep)
            let zSlice = zeroCrossingRates[zStart..<zEnd]
            features.append(zSlice.reduce(0, +) / Float(max(1, zSlice.count)))
            
            let eStep = max(1, frameEnergies.count / 3)
            let eStart = i * eStep
            let eEnd = min(frameEnergies.count, eStart + eStep)
            let eSlice = frameEnergies[eStart..<eEnd]
            features.append(eSlice.reduce(0, +) / Float(max(1, eSlice.count)))
        }
        
        // Pad or truncate to exactly 256
        if features.count < embeddingDimension {
            features.append(contentsOf: [Float](repeating: 0.0, count: embeddingDimension - features.count))
        } else if features.count > embeddingDimension {
            features = Array(features.prefix(embeddingDimension))
        }
        
        // L2 normalize
        let l2Norm = sqrt(features.map { $0 * $0 }.reduce(0, +))
        if l2Norm > 1e-9 {
            for i in 0..<embeddingDimension {
                features[i] /= l2Norm
            }
        }
        
        return features
    }
}
