import Foundation

struct AudioAnalysis {
    let fileInfo: AudioFileInfo
    let dynamicRange: DynamicRangeResult
    let spectral: SpectralResult
    let clipping: ClippingResult
    let stereoImage: StereoImageResult?
    let verdict: MasteringVerdictResult
    let waveformData: WaveformData
    let spectrumData: SpectrumData
}

// MARK: - Dynamic Range

struct DynamicRangeResult {
    let drScore: Double
    let peakDB: Double
    let rmsDB: Double
    let crestFactor: Double
    let integratedLUFS: Double
    let loudnessRange: Double

    var drRating: DRRating {
        switch drScore {
        case 14...: return .excellent
        case 10..<14: return .good
        case 6..<10: return .compressed
        default: return .crushed
        }
    }
}

enum DRRating: String {
    case excellent = "Excellent"
    case good = "Good"
    case compressed = "Compressed"
    case crushed = "Crushed"
}

// MARK: - Spectral Analysis

struct SpectralResult {
    let isSuspiciousUpconvert: Bool
    let detectedCutoffHz: Double?
    let estimatedSourceCodec: String?
    let spectralConfidence: Double
    let averageSpectrum: [Float]
    let frequencyBins: [Float]
}

// MARK: - Clipping

struct ClippingResult {
    let clippedSamples: Int
    let totalSamples: Int
    let clippingPercentage: Double
    let truePeakDB: Double
    let consecutiveClipEvents: Int

    var clippingRating: ClippingRating {
        switch clippingPercentage {
        case 0: return .none
        case ..<0.01: return .minimal
        case ..<0.1: return .moderate
        default: return .severe
        }
    }
}

enum ClippingRating: String {
    case none = "None"
    case minimal = "Minimal"
    case moderate = "Moderate"
    case severe = "Severe"
}

// MARK: - Mastering Verdict

struct MasteringVerdictResult {
    let overall: MasteringVerdict
    let details: [VerdictDetail]
}

enum MasteringVerdict: String {
    case excellent = "Excellent Mastering"
    case good = "Good Mastering"
    case mediocre = "Mediocre Mastering"
    case poor = "Poor Mastering (Loudness War)"
    case suspicious = "Suspicious (Possible Fake Lossless)"
}

struct VerdictDetail {
    let category: String
    let status: VerdictStatus
    let message: String
}

enum VerdictStatus {
    case pass
    case warning
    case fail
}

// MARK: - Stereo Image

struct StereoImageResult {
    let correlation: Double
    let stereoWidth: Double
    let phaseIssuePercentage: Double
    let bandWidths: [(band: String, width: Double)]
    let lissajousPoints: [(x: Float, y: Float)]
}

// MARK: - Visualization Data

struct WaveformData {
    let minSamples: [Float]
    let maxSamples: [Float]
    let rmsEnvelope: [Float]
}

struct SpectrumData {
    let magnitudes: [Float]
    let frequencies: [Float]
    let cutoffMarker: Float?
}
