import Foundation
import Accelerate

final class ClippingDetector {

    /// Detect clipping by scanning for samples at or near 0dBFS,
    /// and compute true peak via 4x oversampling.
    static func analyze(samples: [Float], sampleRate: Double) -> ClippingResult {
        guard !samples.isEmpty else {
            return ClippingResult(
                clippedSamples: 0, totalSamples: 0,
                clippingPercentage: 0, truePeakDB: -100,
                consecutiveClipEvents: 0
            )
        }

        let threshold: Float = 0.9975 // ~-0.02 dBFS
        var clippedCount = 0
        var consecutiveEvents = 0
        var inClipRegion = false

        for sample in samples {
            let absSample = abs(sample)
            if absSample >= threshold {
                clippedCount += 1
                if !inClipRegion {
                    consecutiveEvents += 1
                    inClipRegion = true
                }
            } else {
                inClipRegion = false
            }
        }

        let clippingPercentage = Double(clippedCount) / Double(samples.count) * 100.0

        // True peak via 4x oversampling using vDSP interpolation
        let truePeakDB = computeTruePeak(samples: samples, sampleRate: sampleRate)

        return ClippingResult(
            clippedSamples: clippedCount,
            totalSamples: samples.count,
            clippingPercentage: clippingPercentage,
            truePeakDB: truePeakDB,
            consecutiveClipEvents: consecutiveEvents
        )
    }

    /// Compute true peak by 4x oversampling blocks of audio.
    /// Inter-sample peaks can exceed 0dBFS even when no sample clips.
    private static func computeTruePeak(samples: [Float], sampleRate: Double) -> Double {
        let upsampleFactor = 4
        let blockSize = 1024
        var maxPeak: Float = 0

        // Find peak of original samples first
        vDSP_maxv(samples.map { abs($0) }, 1, &maxPeak, vDSP_Length(samples.count))

        // Check blocks for inter-sample peaks via linear interpolation
        var offset = 0
        while offset + blockSize <= samples.count {
            let block = Array(samples[offset..<(offset + blockSize)])
            let upsampledSize = blockSize * upsampleFactor

            // Simple linear interpolation for oversampling
            var upsampled = [Float](repeating: 0, count: upsampledSize)
            for i in 0..<(blockSize - 1) {
                let s0 = block[i]
                let s1 = block[i + 1]
                for j in 0..<upsampleFactor {
                    let t = Float(j) / Float(upsampleFactor)
                    upsampled[i * upsampleFactor + j] = s0 + (s1 - s0) * t
                }
            }

            var blockPeak: Float = 0
            var absUpsampled = [Float](repeating: 0, count: upsampledSize)
            vDSP_vabs(upsampled, 1, &absUpsampled, 1, vDSP_Length(upsampledSize))
            vDSP_maxv(absUpsampled, 1, &blockPeak, vDSP_Length(upsampledSize))
            maxPeak = max(maxPeak, blockPeak)

            offset += blockSize
        }

        return maxPeak > 0 ? 20.0 * log10(Double(maxPeak)) : -100.0
    }
}
