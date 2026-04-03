import Foundation

final class MasteringVerdictEngine {

    static func evaluate(
        dynamicRange: DynamicRangeResult,
        spectral: SpectralResult,
        clipping: ClippingResult,
        codec: String
    ) -> MasteringVerdictResult {
        var details = [VerdictDetail]()

        // 1. Dynamic Range assessment
        let drDetail: VerdictDetail
        switch dynamicRange.drRating {
        case .excellent:
            drDetail = VerdictDetail(
                category: "Dynamic Range",
                status: .pass,
                message: "DR\(Int(dynamicRange.drScore)) — Excellent dynamic range. Well mastered."
            )
        case .good:
            drDetail = VerdictDetail(
                category: "Dynamic Range",
                status: .pass,
                message: "DR\(Int(dynamicRange.drScore)) — Good dynamic range."
            )
        case .compressed:
            drDetail = VerdictDetail(
                category: "Dynamic Range",
                status: .warning,
                message: "DR\(Int(dynamicRange.drScore)) — Moderately compressed. Some dynamics lost."
            )
        case .crushed:
            drDetail = VerdictDetail(
                category: "Dynamic Range",
                status: .fail,
                message: "DR\(Int(dynamicRange.drScore)) — Severely compressed. Loudness war victim."
            )
        }
        details.append(drDetail)

        // 2. Loudness assessment
        let lufsDetail: VerdictDetail
        let lufs = dynamicRange.integratedLUFS
        if lufs < -14 {
            lufsDetail = VerdictDetail(
                category: "Loudness",
                status: .pass,
                message: String(format: "%.1f LUFS — Conservative loudness. Great for streaming.", lufs)
            )
        } else if lufs < -9 {
            lufsDetail = VerdictDetail(
                category: "Loudness",
                status: .pass,
                message: String(format: "%.1f LUFS — Moderate loudness level.", lufs)
            )
        } else if lufs < -6 {
            lufsDetail = VerdictDetail(
                category: "Loudness",
                status: .warning,
                message: String(format: "%.1f LUFS — Loud master. May cause fatigue.", lufs)
            )
        } else {
            lufsDetail = VerdictDetail(
                category: "Loudness",
                status: .fail,
                message: String(format: "%.1f LUFS — Extremely loud. Likely over-compressed.", lufs)
            )
        }
        details.append(lufsDetail)

        // 3. Clipping assessment
        let clipDetail: VerdictDetail
        switch clipping.clippingRating {
        case .none:
            clipDetail = VerdictDetail(
                category: "Clipping",
                status: .pass,
                message: "No clipping detected. Clean signal."
            )
        case .minimal:
            clipDetail = VerdictDetail(
                category: "Clipping",
                status: .pass,
                message: String(format: "Minimal clipping (%.4f%%). Acceptable.", clipping.clippingPercentage)
            )
        case .moderate:
            clipDetail = VerdictDetail(
                category: "Clipping",
                status: .warning,
                message: String(format: "Moderate clipping (%.3f%%). %d clip events detected.", clipping.clippingPercentage, clipping.consecutiveClipEvents)
            )
        case .severe:
            clipDetail = VerdictDetail(
                category: "Clipping",
                status: .fail,
                message: String(format: "Severe clipping (%.2f%%). %d clip events. Signal is damaged.", clipping.clippingPercentage, clipping.consecutiveClipEvents)
            )
        }
        details.append(clipDetail)

        // 4. True Peak
        let tpDetail: VerdictDetail
        if clipping.truePeakDB <= 0 {
            tpDetail = VerdictDetail(
                category: "True Peak",
                status: .pass,
                message: String(format: "%.1f dBTP — Within digital ceiling.", clipping.truePeakDB)
            )
        } else {
            tpDetail = VerdictDetail(
                category: "True Peak",
                status: .fail,
                message: String(format: "+%.1f dBTP — Inter-sample peaks exceed 0dBFS!", clipping.truePeakDB)
            )
        }
        details.append(tpDetail)

        // 5. Lossy detection (skip for DSD - our own FIR filter creates a sharp cutoff)
        let isDSD = codec.uppercased().contains("DSD")
        let lossyDetail: VerdictDetail
        if spectral.isSuspiciousUpconvert && !isDSD {
            let cutoffStr = spectral.detectedCutoffHz.map { String(format: "%.0f Hz", $0) } ?? "unknown"
            let codecStr = spectral.estimatedSourceCodec ?? "unknown lossy codec"
            lossyDetail = VerdictDetail(
                category: "Authenticity",
                status: .fail,
                message: "SUSPICIOUS: Spectral cutoff at \(cutoffStr). Likely upconverted from \(codecStr). Confidence: \(Int(spectral.spectralConfidence * 100))%."
            )
        } else if isDSD {
            lossyDetail = VerdictDetail(
                category: "Authenticity",
                status: .pass,
                message: "DSD native format. Spectral cutoff from decimation filter (not lossy)."
            )
        } else {
            lossyDetail = VerdictDetail(
                category: "Authenticity",
                status: .pass,
                message: "No spectral anomalies detected. File appears to be genuine lossless."
            )
        }
        details.append(lossyDetail)

        // 6. Loudness Range
        let lraDetail: VerdictDetail
        if dynamicRange.loudnessRange > 10 {
            lraDetail = VerdictDetail(
                category: "Loudness Range",
                status: .pass,
                message: String(format: "LRA %.1f dB — Wide loudness range. Dynamic performance.", dynamicRange.loudnessRange)
            )
        } else if dynamicRange.loudnessRange > 5 {
            lraDetail = VerdictDetail(
                category: "Loudness Range",
                status: .pass,
                message: String(format: "LRA %.1f dB — Moderate loudness range.", dynamicRange.loudnessRange)
            )
        } else {
            lraDetail = VerdictDetail(
                category: "Loudness Range",
                status: .warning,
                message: String(format: "LRA %.1f dB — Narrow loudness range. Limited dynamics.", dynamicRange.loudnessRange)
            )
        }
        details.append(lraDetail)

        // Overall verdict
        let overall = computeOverall(
            dr: dynamicRange,
            spectral: spectral,
            clipping: clipping,
            isDSD: isDSD
        )

        return MasteringVerdictResult(overall: overall, details: details)
    }

    private static func computeOverall(
        dr: DynamicRangeResult,
        spectral: SpectralResult,
        clipping: ClippingResult,
        isDSD: Bool = false
    ) -> MasteringVerdict {
        // Fake lossless overrides everything (but not for DSD)
        if !isDSD && spectral.isSuspiciousUpconvert && spectral.spectralConfidence > 0.6 {
            return .suspicious
        }

        // Score-based assessment
        var score = 0

        switch dr.drRating {
        case .excellent: score += 4
        case .good: score += 3
        case .compressed: score += 1
        case .crushed: score += 0
        }

        switch clipping.clippingRating {
        case .none: score += 3
        case .minimal: score += 2
        case .moderate: score += 1
        case .severe: score += 0
        }

        if dr.integratedLUFS < -10 { score += 2 }
        else if dr.integratedLUFS < -7 { score += 1 }

        if clipping.truePeakDB <= -1 { score += 1 }

        switch score {
        case 8...: return .excellent
        case 5..<8: return .good
        case 3..<5: return .mediocre
        default: return .poor
        }
    }
}
