import SwiftUI

struct AnalysisResultView: View {
    let analysis: AudioAnalysis
    let onNewFile: () -> Void
    var backLabel: String = "New File"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with file info
                headerSection

                // Verdict
                VerdictBadgeView(verdict: analysis.verdict)

                // Metrics grid
                metricsGrid

                // Waveform
                WaveformView(
                    waveform: analysis.waveformData,
                    clipping: analysis.clipping
                )

                // Spectrum
                SpectrumView(
                    spectrumData: analysis.spectrumData,
                    spectralResult: analysis.spectral,
                    sampleRate: analysis.fileInfo.sampleRate
                )

                // Stereo Image (only for stereo files)
                if let stereo = analysis.stereoImage {
                    StereoImageView(stereo: stereo)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(analysis.fileInfo.fileName)
                    .font(.title2.bold())
                    .lineLimit(1)

                HStack(spacing: 16) {
                    infoTag(analysis.fileInfo.codec, icon: "doc.fill")
                    infoTag(analysis.fileInfo.sampleRateFormatted, icon: "waveform")
                    infoTag("\(analysis.fileInfo.bitDepth)-bit", icon: "number")
                    infoTag("\(analysis.fileInfo.channels)ch", icon: "speaker.wave.2.fill")
                    infoTag(analysis.fileInfo.durationFormatted, icon: "clock")
                    infoTag(analysis.fileInfo.fileSizeFormatted, icon: "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onNewFile()
            } label: {
                Label(backLabel, systemImage: backLabel == "New File" ? "plus.circle" : "arrow.left.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoTag(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            metricCard(
                title: "DR Score",
                value: String(format: "DR%.0f", analysis.dynamicRange.drScore),
                subtitle: analysis.dynamicRange.drRating.rawValue,
                color: drColor
            )

            metricCard(
                title: "Integrated LUFS",
                value: String(format: "%.1f", analysis.dynamicRange.integratedLUFS),
                subtitle: "LUFS",
                color: lufsColor
            )

            metricCard(
                title: "True Peak",
                value: String(format: "%.1f", analysis.clipping.truePeakDB),
                subtitle: "dBTP",
                color: analysis.clipping.truePeakDB > -1 ? .red : .green
            )

            metricCard(
                title: "Clipping",
                value: analysis.clipping.clippingRating.rawValue,
                subtitle: String(format: "%.3f%%", analysis.clipping.clippingPercentage),
                color: clipColor
            )

            metricCard(
                title: "Peak Level",
                value: String(format: "%.1f", analysis.dynamicRange.peakDB),
                subtitle: "dBFS",
                color: analysis.dynamicRange.peakDB > -1 ? .red : .blue
            )

            metricCard(
                title: "RMS Level",
                value: String(format: "%.1f", analysis.dynamicRange.rmsDB),
                subtitle: "dBFS",
                color: .blue
            )

            metricCard(
                title: "Crest Factor",
                value: String(format: "%.1f", analysis.dynamicRange.crestFactor),
                subtitle: "Peak/RMS",
                color: analysis.dynamicRange.crestFactor > 4 ? .green : .orange
            )

            metricCard(
                title: "Loudness Range",
                value: String(format: "%.1f", analysis.dynamicRange.loudnessRange),
                subtitle: "LRA dB",
                color: analysis.dynamicRange.loudnessRange > 7 ? .green : .orange
            )
        }
    }

    private func metricCard(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(color)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Colors

    private var drColor: Color {
        switch analysis.dynamicRange.drRating {
        case .excellent: return .green
        case .good: return .blue
        case .compressed: return .orange
        case .crushed: return .red
        }
    }

    private var lufsColor: Color {
        let lufs = analysis.dynamicRange.integratedLUFS
        if lufs < -14 { return .green }
        if lufs < -9 { return .blue }
        if lufs < -6 { return .orange }
        return .red
    }

    private var clipColor: Color {
        switch analysis.clipping.clippingRating {
        case .none: return .green
        case .minimal: return .blue
        case .moderate: return .orange
        case .severe: return .red
        }
    }
}
