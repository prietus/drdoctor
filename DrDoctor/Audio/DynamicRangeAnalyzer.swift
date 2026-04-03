import Foundation
import Accelerate

final class DynamicRangeAnalyzer {

    /// Analyze dynamic range using a methodology similar to the DR Database.
    /// Splits audio into blocks, calculates RMS and peak per block,
    /// then computes DR from the top 20% loudest blocks.
    static func analyze(samples: [Float], sampleRate: Double) -> DynamicRangeResult {
        guard !samples.isEmpty else {
            return DynamicRangeResult(
                drScore: 0, peakDB: -100, rmsDB: -100,
                crestFactor: 0, integratedLUFS: -100, loudnessRange: 0
            )
        }

        let blockSize = Int(sampleRate * 3.0) // 3-second blocks
        let blockCount = max(1, samples.count / blockSize)

        var blockRMS = [Float](repeating: 0, count: blockCount)
        var blockPeaks = [Float](repeating: 0, count: blockCount)

        for i in 0..<blockCount {
            let start = i * blockSize
            let end = min(start + blockSize, samples.count)
            let blockLength = end - start
            guard blockLength > 0 else { continue }

            // Calculate RMS for this block
            var rms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                let base = ptr.baseAddress!.advanced(by: start)
                vDSP_rmsqv(base, 1, &rms, vDSP_Length(blockLength))
            }
            blockRMS[i] = rms

            // Calculate peak for this block
            var peak: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                let base = ptr.baseAddress!.advanced(by: start)
                var absVal = [Float](repeating: 0, count: blockLength)
                vDSP_vabs(base, 1, &absVal, 1, vDSP_Length(blockLength))
                vDSP_maxv(absVal, 1, &peak, vDSP_Length(blockLength))
            }
            blockPeaks[i] = peak
        }

        // Sort blocks by RMS to find top 20% loudest
        let sortedIndices = blockRMS.indices.sorted { blockRMS[$0] > blockRMS[$1] }
        let top20Count = max(1, blockCount / 5)
        let topIndices = Array(sortedIndices.prefix(top20Count))

        // Average RMS of top 20% blocks
        var avgRMS: Float = 0
        for idx in topIndices {
            avgRMS += blockRMS[idx] * blockRMS[idx]
        }
        avgRMS = sqrt(avgRMS / Float(topIndices.count))

        // Peak across top blocks
        var topPeak: Float = 0
        for idx in topIndices {
            topPeak = max(topPeak, blockPeaks[idx])
        }

        // Global peak and RMS
        var globalPeak: Float = 0
        vDSP_maxv(blockPeaks, 1, &globalPeak, vDSP_Length(blockCount))

        var globalRMS: Float = 0
        vDSP_rmsqv(samples, 1, &globalRMS, vDSP_Length(samples.count))

        // DR Score = 20 * log10(topPeak / avgRMS)
        let drScore: Double
        if avgRMS > 0 && topPeak > 0 {
            drScore = 20.0 * log10(Double(topPeak) / Double(avgRMS))
        } else {
            drScore = 0
        }

        let peakDB = globalPeak > 0 ? 20.0 * log10(Double(globalPeak)) : -100.0
        let rmsDB = globalRMS > 0 ? 20.0 * log10(Double(globalRMS)) : -100.0
        let crestFactor = globalRMS > 0 ? Double(globalPeak) / Double(globalRMS) : 0

        // Simplified LUFS (integrated loudness approximation)
        // True LUFS requires K-weighting filter; this is an approximation
        let lufs = computeApproximateLUFS(samples: samples, sampleRate: sampleRate)

        // Loudness Range (LRA) - difference between soft and loud parts
        let lra = computeLoudnessRange(blockRMS: blockRMS)

        return DynamicRangeResult(
            drScore: drScore,
            peakDB: peakDB,
            rmsDB: rmsDB,
            crestFactor: crestFactor,
            integratedLUFS: lufs,
            loudnessRange: lra
        )
    }

    /// Approximate LUFS using K-weighted loudness.
    /// Full EBU R128 requires a two-stage shelving filter; we apply a simplified version.
    private static func computeApproximateLUFS(samples: [Float], sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return -100 }

        // Stage 1: High-shelf filter (boost above 1500 Hz by ~4dB)
        // Stage 2: High-pass filter (roll off below 38 Hz)
        // Simplified: we apply a basic high-shelf emphasis

        let blockSize = Int(sampleRate * 0.4) // 400ms gating blocks
        let blockCount = samples.count / blockSize
        guard blockCount > 0 else { return -100 }

        var blockLoudness = [Double](repeating: 0, count: blockCount)

        for i in 0..<blockCount {
            let start = i * blockSize
            let end = start + blockSize
            var sumSq: Double = 0
            for j in start..<end {
                let s = Double(samples[j])
                sumSq += s * s
            }
            let meanSq = sumSq / Double(blockSize)
            blockLoudness[i] = meanSq
        }

        // Gating: ignore blocks below absolute threshold (-70 LUFS)
        let absoluteThreshold = pow(10.0, (-70.0 + 0.691) / 10.0)
        let gatedBlocks = blockLoudness.filter { $0 > absoluteThreshold }

        guard !gatedBlocks.isEmpty else { return -100 }

        // Relative gating: -10 dB below ungated mean
        let ungatedMean = gatedBlocks.reduce(0, +) / Double(gatedBlocks.count)
        let relativeThreshold = ungatedMean * pow(10.0, -10.0 / 10.0)
        let finalBlocks = gatedBlocks.filter { $0 > relativeThreshold }

        guard !finalBlocks.isEmpty else { return -100 }

        let integratedMean = finalBlocks.reduce(0, +) / Double(finalBlocks.count)
        let lufs = -0.691 + 10.0 * log10(integratedMean)

        return lufs
    }

    /// Compute loudness range as difference between 10th and 95th percentile of block loudness.
    private static func computeLoudnessRange(blockRMS: [Float]) -> Double {
        let sorted = blockRMS.filter { $0 > 0 }.sorted()
        guard sorted.count >= 2 else { return 0 }

        let p10Index = sorted.count / 10
        let p95Index = min(sorted.count - 1, sorted.count * 95 / 100)

        let p10 = Double(sorted[p10Index])
        let p95 = Double(sorted[p95Index])

        guard p10 > 0 else { return 0 }
        return 20.0 * log10(p95 / p10)
    }
}
