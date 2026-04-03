import Foundation
import Accelerate

final class SpectralAnalyzer {

    /// Perform FFT-based spectral analysis to detect lossy upconversion.
    /// Analyzes the average frequency spectrum looking for sharp cutoffs
    /// that indicate the file was transcoded from a lossy source.
    static func analyze(samples: [Float], sampleRate: Double) -> SpectralResult {
        let fftSize = 8192
        let hopSize = fftSize / 2
        let halfFFT = fftSize / 2

        guard samples.count >= fftSize else {
            return SpectralResult(
                isSuspiciousUpconvert: false,
                detectedCutoffHz: nil,
                estimatedSourceCodec: nil,
                spectralConfidence: 0,
                averageSpectrum: [],
                frequencyBins: []
            )
        }

        // Setup FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return SpectralResult(
                isSuspiciousUpconvert: false, detectedCutoffHz: nil,
                estimatedSourceCodec: nil, spectralConfidence: 0,
                averageSpectrum: [], frequencyBins: []
            )
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Create Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Accumulate magnitude spectrum
        var avgMagnitude = [Float](repeating: 0, count: halfFFT)
        var windowCount: Float = 0

        let totalWindows = (samples.count - fftSize) / hopSize
        // Limit to 200 windows for performance
        let stride = max(1, totalWindows / 200)

        var windowIndex = 0
        var offset = 0
        while offset + fftSize <= samples.count {
            windowIndex += 1
            if windowIndex % stride != 0 && totalWindows > 200 {
                offset += hopSize
                continue
            }

            // Apply window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(samples[offset..<(offset + fftSize)]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // FFT
            var realPart = [Float](repeating: 0, count: halfFFT)
            var imagPart = [Float](repeating: 0, count: halfFFT)

            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    windowed.withUnsafeBufferPointer { windowedBuf in
                        windowedBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFT) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfFFT))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Magnitude
                    var magnitude = [Float](repeating: 0, count: halfFFT)
                    vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(halfFFT))

                    // Accumulate
                    vDSP_vadd(avgMagnitude, 1, magnitude, 1, &avgMagnitude, 1, vDSP_Length(halfFFT))
                }
            }

            windowCount += 1
            offset += hopSize
        }

        // Average
        guard windowCount > 0 else {
            return SpectralResult(
                isSuspiciousUpconvert: false, detectedCutoffHz: nil,
                estimatedSourceCodec: nil, spectralConfidence: 0,
                averageSpectrum: [], frequencyBins: []
            )
        }

        var count = windowCount
        vDSP_vsdiv(avgMagnitude, 1, &count, &avgMagnitude, 1, vDSP_Length(halfFFT))

        // Convert to dB
        var one: Float = 1e-10
        vDSP_vsadd(avgMagnitude, 1, &one, &avgMagnitude, 1, vDSP_Length(halfFFT))
        var dbSpectrum = [Float](repeating: 0, count: halfFFT)
        var n = Int32(halfFFT)
        vvlog10f(&dbSpectrum, avgMagnitude, &n)
        var twenty: Float = 20.0
        vDSP_vsmul(dbSpectrum, 1, &twenty, &dbSpectrum, 1, vDSP_Length(halfFFT))

        // Generate frequency bins
        let freqResolution = Float(sampleRate) / Float(fftSize)
        var frequencyBins = [Float](repeating: 0, count: halfFFT)
        for i in 0..<halfFFT {
            frequencyBins[i] = Float(i) * freqResolution
        }

        // Detect spectral cutoff
        let (cutoffHz, confidence, codec) = detectSpectralCutoff(
            spectrum: dbSpectrum,
            frequencies: frequencyBins,
            sampleRate: sampleRate
        )

        // Downsample spectrum for display (512 points max)
        let displaySize = min(512, halfFFT)
        let displayStep = halfFFT / displaySize
        var displaySpectrum = [Float](repeating: 0, count: displaySize)
        var displayFreqs = [Float](repeating: 0, count: displaySize)
        for i in 0..<displaySize {
            displaySpectrum[i] = dbSpectrum[i * displayStep]
            displayFreqs[i] = frequencyBins[i * displayStep]
        }

        return SpectralResult(
            isSuspiciousUpconvert: cutoffHz != nil && confidence > 0.6,
            detectedCutoffHz: cutoffHz,
            estimatedSourceCodec: codec,
            spectralConfidence: confidence,
            averageSpectrum: displaySpectrum,
            frequencyBins: displayFreqs
        )
    }

    /// Detect sharp spectral cutoff by analyzing the gradient of the spectrum.
    /// Lossy codecs produce a characteristic steep drop-off at their frequency limit.
    private static func detectSpectralCutoff(
        spectrum: [Float],
        frequencies: [Float],
        sampleRate: Double
    ) -> (Double?, Double, String?) {
        guard spectrum.count > 100 else { return (nil, 0, nil) }

        // Only analyze frequencies above 10kHz (below that is normal content)
        let minAnalysisHz: Float = 10000
        let maxAnalysisHz = Float(sampleRate / 2) * 0.95

        guard let startIdx = frequencies.firstIndex(where: { $0 >= minAnalysisHz }),
              let endIdx = frequencies.lastIndex(where: { $0 <= maxAnalysisHz }),
              endIdx > startIdx + 20 else {
            return (nil, 0, nil)
        }

        // Smooth the spectrum with a moving average
        let smoothWindow = 5
        var smoothed = [Float](repeating: 0, count: endIdx - startIdx)
        for i in 0..<smoothed.count {
            let start = max(0, i - smoothWindow)
            let end = min(smoothed.count - 1, i + smoothWindow)
            var sum: Float = 0
            for j in start...end {
                sum += spectrum[startIdx + j]
            }
            smoothed[i] = sum / Float(end - start + 1)
        }

        // Calculate gradient (dB/bin)
        var gradient = [Float](repeating: 0, count: smoothed.count - 1)
        for i in 0..<gradient.count {
            gradient[i] = smoothed[i + 1] - smoothed[i]
        }

        // Find the steepest drop (most negative gradient region)
        var steepestDropIdx = 0
        var steepestDropValue: Float = 0
        let regionSize = 10

        for i in 0..<(gradient.count - regionSize) {
            var regionDrop: Float = 0
            for j in 0..<regionSize {
                regionDrop += gradient[i + j]
            }
            if regionDrop < steepestDropValue {
                steepestDropValue = regionDrop
                steepestDropIdx = i
            }
        }

        // Calculate the average level before and after the drop
        let beforeStart = max(0, steepestDropIdx - 30)
        let beforeEnd = steepestDropIdx
        let afterStart = min(steepestDropIdx + regionSize, smoothed.count - 1)
        let afterEnd = min(afterStart + 30, smoothed.count - 1)

        guard afterEnd > afterStart && beforeEnd > beforeStart else {
            return (nil, 0, nil)
        }

        let beforeLevel = smoothed[beforeStart...beforeEnd].reduce(0, +) / Float(beforeEnd - beforeStart + 1)
        let afterLevel = smoothed[afterStart...afterEnd].reduce(0, +) / Float(afterEnd - afterStart + 1)
        let dropDB = beforeLevel - afterLevel

        // A genuine lossless file has gradual roll-off; lossy has sharp drops > 20dB
        guard dropDB > 15 else {
            return (nil, 0, nil)
        }

        let cutoffFreq = Double(frequencies[startIdx + steepestDropIdx])
        let confidence = min(1.0, Double(dropDB - 15) / 25.0)

        // Estimate source codec based on cutoff frequency
        let codec: String?
        switch cutoffFreq {
        case ..<16500:
            codec = "MP3 128 kbps (or lower)"
        case 16500..<18000:
            codec = "MP3 192 kbps / OGG ~Q5"
        case 18000..<19500:
            codec = "MP3 256 kbps / AAC 192 kbps"
        case 19500..<20500:
            codec = "MP3 320 kbps / AAC 256 kbps"
        case 20500..<21500:
            codec = "AAC 320 kbps / OGG ~Q8"
        default:
            codec = nil
        }

        return (cutoffFreq, confidence, codec)
    }
}
