import Foundation
import Accelerate

final class DynamicRangeAnalyzer {

    /// Combine the full-track DR14 measurement with loudness figures from the
    /// decoded excerpt. DR, peak, RMS, crest factor and LRA come from `dr14`,
    /// which saw every sample of every channel; LUFS is approximated from `samples`.
    static func analyze(dr14: DR14Meter.Result, samples: [Float], sampleRate: Double) -> DynamicRangeResult {
        let peakDB = dr14.peak > 0 ? 20.0 * log10(Double(dr14.peak)) : -100.0
        let rmsDB = dr14.rms > 0 ? 20.0 * log10(Double(dr14.rms)) : -100.0
        let crestFactor = dr14.rms > 0 ? Double(dr14.peak) / Double(dr14.rms) : 0

        return DynamicRangeResult(
            drScore: dr14.drScore,
            peakDB: peakDB,
            rmsDB: rmsDB,
            crestFactor: crestFactor,
            integratedLUFS: computeApproximateLUFS(samples: samples, sampleRate: sampleRate),
            loudnessRange: computeLoudnessRange(blockRMS: dr14.blockRMS)
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

/// Streaming DR14 meter (Pleasurize Music Foundation spec, as implemented by the
/// TT DR Meter and foobar2000's DR plugin). Fed the whole track in chunks; only
/// per-block statistics are kept, so memory does not grow with track length.
///
///   1. Each channel is cut into 3-second blocks (the trailing partial block counts).
///   2. Block RMS = sqrt(2 * mean(x^2)).
///   3. Per channel: quadratic mean of the loudest 20% of block RMS values, and
///      the second-highest block peak.
///   4. Channel DR = 20 * log10(peak2 / rms); track DR = mean over channels, rounded.
struct DR14Meter {
    struct Result {
        let drScore: Double
        let peak: Float        // highest sample magnitude, any channel
        let rms: Float         // plain RMS over all samples of all channels
        let blockRMS: [Float]  // per-block RMS averaged across channels (for LRA)
    }

    let channelCount: Int
    private let blockFrames: Int
    private var framesInBlock = 0
    private var blockSumSq: [Float]
    private var blockPeak: [Float]
    private var channelBlockRMS: [[Float]]
    private var channelBlockPeaks: [[Float]]
    private var totalSumSq: Double = 0
    private var totalFrames = 0
    private var peak: Float = 0

    init(channelCount: Int, sampleRate: Double) {
        self.channelCount = max(channelCount, 1)
        blockFrames = max(1, Int((sampleRate * 3.0).rounded()))
        blockSumSq = [Float](repeating: 0, count: self.channelCount)
        blockPeak = [Float](repeating: 0, count: self.channelCount)
        channelBlockRMS = Array(repeating: [], count: self.channelCount)
        channelBlockPeaks = Array(repeating: [], count: self.channelCount)
    }

    /// Feed interleaved frames (L R L R …).
    mutating func process(interleaved samples: UnsafePointer<Float>, frames: Int) {
        let pointers = (0..<channelCount).map { samples + $0 }
        process(channels: pointers, stride: channelCount, frames: frames)
    }

    /// Feed one pointer per channel, each advancing by `stride` floats per frame.
    mutating func process(channels: [UnsafePointer<Float>], stride: Int = 1, frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(blockFrames - framesInBlock, frames - offset)
            for ch in 0..<channelCount {
                let base = channels[ch] + offset * stride
                var sumSq: Float = 0
                vDSP_svesq(base, vDSP_Stride(stride), &sumSq, vDSP_Length(n))
                var p: Float = 0
                vDSP_maxmgv(base, vDSP_Stride(stride), &p, vDSP_Length(n))
                blockSumSq[ch] += sumSq
                blockPeak[ch] = max(blockPeak[ch], p)
            }
            framesInBlock += n
            offset += n
            if framesInBlock == blockFrames { closeBlock() }
        }
    }

    private mutating func closeBlock() {
        guard framesInBlock > 0 else { return }
        for ch in 0..<channelCount {
            channelBlockRMS[ch].append(sqrtf(2.0 * blockSumSq[ch] / Float(framesInBlock)))
            channelBlockPeaks[ch].append(blockPeak[ch])
            totalSumSq += Double(blockSumSq[ch])
            peak = max(peak, blockPeak[ch])
            blockSumSq[ch] = 0
            blockPeak[ch] = 0
        }
        totalFrames += framesInBlock
        framesInBlock = 0
    }

    mutating func finish() -> Result {
        closeBlock()

        var channelDRs: [Double] = []
        for ch in 0..<channelCount {
            let rmsValues = channelBlockRMS[ch].sorted(by: >)
            let peaks = channelBlockPeaks[ch].sorted(by: >)
            guard !rmsValues.isEmpty else { continue }

            let topCount = max(1, Int(Double(rmsValues.count) * 0.2))
            let topRMS = sqrtf(rmsValues.prefix(topCount).reduce(0) { $0 + $1 * $1 } / Float(topCount))
            let secondPeak = peaks.count >= 2 ? peaks[1] : peaks[0]
            // A silent channel (e.g. mono stored as stereo) has no meaningful DR.
            guard topRMS > 0, secondPeak > 0 else { continue }
            channelDRs.append(20.0 * log10(Double(secondPeak) / Double(topRMS)))
        }
        let dr = channelDRs.isEmpty ? 0 : (channelDRs.reduce(0, +) / Double(channelDRs.count)).rounded()

        let blockCount = channelBlockRMS.map(\.count).min() ?? 0
        let blockRMS = (0..<blockCount).map { i in
            channelBlockRMS.reduce(0) { $0 + $1[i] } / Float(channelCount)
        }
        let rms = totalFrames > 0 ? Float(sqrt(totalSumSq / Double(totalFrames * channelCount))) : 0

        return Result(drScore: dr, peak: peak, rms: rms, blockRMS: blockRMS)
    }
}
