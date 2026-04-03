import Foundation
import Accelerate

final class StereoAnalyzer {

    static func analyze(left: [Float], right: [Float], sampleRate: Double) -> StereoImageResult {
        let count = min(left.count, right.count)
        guard count > 0 else {
            return StereoImageResult(
                correlation: 1.0, stereoWidth: 0, phaseIssuePercentage: 0,
                bandWidths: [], lissajousPoints: []
            )
        }

        // 1. Correlation coefficient (Pearson) using vDSP
        let correlation = computeCorrelation(left: left, right: right, count: count)

        // 2. Stereo width: RMS(side) / RMS(mid)
        let stereoWidth = computeStereoWidth(left: left, right: right, count: count)

        // 3. Phase issues: percentage of samples where L and R have opposite sign
        let phaseIssues = computePhaseIssues(left: left, right: right, count: count)

        // 4. Per-band stereo width
        let bandWidths = computeBandWidths(left: left, right: right, count: count, sampleRate: sampleRate)

        // 5. Lissajous points for vectorscope (downsample to ~5000 points)
        let lissajous = computeLissajousPoints(left: left, right: right, count: count)

        return StereoImageResult(
            correlation: correlation,
            stereoWidth: stereoWidth,
            phaseIssuePercentage: phaseIssues,
            bandWidths: bandWidths,
            lissajousPoints: lissajous
        )
    }

    // MARK: - Correlation

    private static func computeCorrelation(left: [Float], right: [Float], count: Int) -> Double {
        var dotLR: Float = 0
        var dotLL: Float = 0
        var dotRR: Float = 0
        vDSP_dotpr(left, 1, right, 1, &dotLR, vDSP_Length(count))
        vDSP_dotpr(left, 1, left, 1, &dotLL, vDSP_Length(count))
        vDSP_dotpr(right, 1, right, 1, &dotRR, vDSP_Length(count))

        let denom = sqrt(Double(dotLL) * Double(dotRR))
        guard denom > 0 else { return 1.0 }
        return Double(dotLR) / denom
    }

    // MARK: - Stereo Width

    private static func computeStereoWidth(left: [Float], right: [Float], count: Int) -> Double {
        // Mid = (L + R) / 2, Side = (L - R) / 2
        var mid = [Float](repeating: 0, count: count)
        var side = [Float](repeating: 0, count: count)
        vDSP_vadd(left, 1, right, 1, &mid, 1, vDSP_Length(count))
        vDSP_vsub(right, 1, left, 1, &side, 1, vDSP_Length(count))

        var rmsMid: Float = 0
        var rmsSide: Float = 0
        vDSP_rmsqv(mid, 1, &rmsMid, vDSP_Length(count))
        vDSP_rmsqv(side, 1, &rmsSide, vDSP_Length(count))

        guard rmsMid > 0 else { return 0 }
        return Double(rmsSide) / Double(rmsMid)
    }

    // MARK: - Phase Issues

    private static func computePhaseIssues(left: [Float], right: [Float], count: Int) -> Double {
        let threshold: Float = 0.01
        var antiPhaseCount = 0

        // Check blocks for efficiency
        let blockSize = 1024
        for blockStart in stride(from: 0, to: count, by: blockSize) {
            let blockEnd = min(blockStart + blockSize, count)
            for i in blockStart..<blockEnd {
                let l = left[i]
                let r = right[i]
                if abs(l) > threshold && abs(r) > threshold {
                    if (l > 0 && r < 0) || (l < 0 && r > 0) {
                        antiPhaseCount += 1
                    }
                }
            }
        }

        return Double(antiPhaseCount) / Double(count) * 100.0
    }

    // MARK: - Per-Band Stereo Width

    private static func computeBandWidths(
        left: [Float], right: [Float], count: Int, sampleRate: Double
    ) -> [(band: String, width: Double)] {
        let bands: [(name: String, low: Double, high: Double)] = [
            ("Sub", 20, 80),
            ("Bass", 80, 300),
            ("Mid", 300, 2000),
            ("Presence", 2000, 8000),
            ("Air", 8000, 20000)
        ]

        let fftSize = 4096
        guard count >= fftSize else {
            return bands.map { ($0.name, 0.0) }
        }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return bands.map { ($0.name, 0.0) }
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfFFT = fftSize / 2
        let freqResolution = sampleRate / Double(fftSize)

        // Average over multiple windows
        var leftMag = [Float](repeating: 0, count: halfFFT)
        var rightMag = [Float](repeating: 0, count: halfFFT)
        let hopSize = fftSize
        let windowCount = min(count / hopSize, 20)
        guard windowCount > 0 else {
            return bands.map { ($0.name, 0.0) }
        }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        func accumulateFFT(channel: [Float], offset: Int, accum: inout [Float]) {
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(channel[offset..<(offset + fftSize)]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            var realp = [Float](repeating: 0, count: halfFFT)
            var imagp = [Float](repeating: 0, count: halfFFT)
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    windowed.withUnsafeBufferPointer { wBuf in
                        wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFT) { ptr in
                            vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfFFT))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    var mag = [Float](repeating: 0, count: halfFFT)
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(halfFFT))
                    vDSP_vadd(accum, 1, mag, 1, &accum, 1, vDSP_Length(halfFFT))
                }
            }
        }

        for w in 0..<windowCount {
            let offset = w * hopSize
            accumulateFFT(channel: left, offset: offset, accum: &leftMag)
            accumulateFFT(channel: right, offset: offset, accum: &rightMag)
        }

        // Compute per-band width as ratio of side/mid energy
        return bands.map { band in
            let lowBin = max(1, Int(band.low / freqResolution))
            let highBin = min(halfFFT - 1, Int(band.high / freqResolution))
            guard highBin > lowBin else { return (band.name, 0.0) }

            var midEnergy: Float = 0
            var sideEnergy: Float = 0
            for bin in lowBin...highBin {
                let l = leftMag[bin]
                let r = rightMag[bin]
                let m = (sqrt(l) + sqrt(r)) / 2
                let s = abs(sqrt(l) - sqrt(r))
                midEnergy += m * m
                sideEnergy += s * s
            }

            guard midEnergy > 0 else { return (band.name, 0.0) }
            return (band.name, Double(sqrt(sideEnergy / midEnergy)))
        }
    }

    // MARK: - Lissajous

    private static func computeLissajousPoints(
        left: [Float], right: [Float], count: Int
    ) -> [(x: Float, y: Float)] {
        let targetPoints = 5000
        let step = max(1, count / targetPoints)
        var points = [(x: Float, y: Float)]()
        points.reserveCapacity(targetPoints)

        for i in stride(from: 0, to: count, by: step) {
            // Rotate 45 degrees: x = (L+R)/√2, y = (L-R)/√2
            let mid = (left[i] + right[i]) * 0.7071
            let side = (left[i] - right[i]) * 0.7071
            points.append((x: mid, y: side))
        }

        return points
    }
}
