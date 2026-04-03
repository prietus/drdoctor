import SwiftUI

struct StereoImageView: View {
    let stereo: StereoImageResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stereo Image", systemImage: "speaker.wave.2.fill")
                .font(.headline)

            HStack(spacing: 16) {
                // Vectorscope
                vectorscope
                    .frame(width: 220, height: 220)

                // Metrics
                VStack(alignment: .leading, spacing: 12) {
                    correlationMeter
                    stereoWidthMeter
                    phaseIndicator
                    bandWidthBars
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Vectorscope

    private var vectorscope: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let cy = h / 2

            // Background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.3)))

            // Grid lines
            let gridColor = Color.white.opacity(0.1)
            for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
                let rad = angle * .pi / 180
                var line = Path()
                line.move(to: CGPoint(x: cx, y: cy))
                line.addLine(to: CGPoint(
                    x: cx + cos(rad) * cx * 0.9,
                    y: cy + sin(rad) * cy * 0.9
                ))
                context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
            }

            // Labels
            context.draw(Text("L").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: cx - cx * 0.75, y: cy - cy * 0.75))
            context.draw(Text("R").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: cx + cx * 0.75, y: cy - cy * 0.75))
            context.draw(Text("M").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: cx, y: 8))
            context.draw(Text("S").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: cx, y: h - 8))

            // Draw Lissajous points
            let scale = min(cx, cy) * 0.85
            for point in stereo.lissajousPoints {
                let px = cx + CGFloat(point.x) * scale
                let py = cy - CGFloat(point.y) * scale
                let dot = Path(ellipseIn: CGRect(x: px - 0.5, y: py - 0.5, width: 1, height: 1))
                context.fill(dot, with: .color(.cyan.opacity(0.15)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
    }

    // MARK: - Correlation Meter

    private var correlationMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Correlation")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", stereo.correlation))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(correlationColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))

                    // Center marker at 0
                    let centerX = geo.size.width / 2
                    let value = CGFloat((stereo.correlation + 1) / 2) // map -1..1 to 0..1
                    let barWidth = abs(value - 0.5) * geo.size.width

                    RoundedRectangle(cornerRadius: 3)
                        .fill(correlationColor)
                        .frame(width: barWidth)
                        .offset(x: value >= 0.5 ? centerX : centerX - barWidth)

                    // Center line
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: centerX)
                }
            }
            .frame(height: 8)

            HStack {
                Text("-1").font(.system(size: 8)).foregroundStyle(.quaternary)
                Spacer()
                Text("0").font(.system(size: 8)).foregroundStyle(.quaternary)
                Spacer()
                Text("+1").font(.system(size: 8)).foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: - Stereo Width

    private var stereoWidthMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stereo Width")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", stereo.stereoWidth * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(widthColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(widthColor)
                        .frame(width: min(CGFloat(stereo.stereoWidth) * geo.size.width, geo.size.width))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Phase Indicator

    private var phaseIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: phaseIcon)
                .foregroundStyle(phaseColor)
            Text("Phase: \(String(format: "%.1f%%", stereo.phaseIssuePercentage)) anti-phase")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Band Width Bars

    private var bandWidthBars: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stereo Width by Band")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(Array(stereo.bandWidths.enumerated()), id: \.offset) { _, band in
                HStack(spacing: 8) {
                    Text(band.band)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 55, alignment: .trailing)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.cyan.opacity(0.6))
                                .frame(width: min(CGFloat(band.width) * geo.size.width, geo.size.width))
                        }
                    }
                    .frame(height: 6)

                    Text(String(format: "%.0f%%", band.width * 100))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.quaternary)
                        .frame(width: 30)
                }
            }
        }
    }

    // MARK: - Colors

    private var correlationColor: Color {
        if stereo.correlation > 0.8 { return .green }
        if stereo.correlation > 0.3 { return .cyan }
        if stereo.correlation > 0 { return .orange }
        return .red
    }

    private var widthColor: Color {
        if stereo.stereoWidth < 0.3 { return .blue }
        if stereo.stereoWidth < 0.7 { return .cyan }
        if stereo.stereoWidth < 1.0 { return .green }
        return .orange
    }

    private var phaseColor: Color {
        if stereo.phaseIssuePercentage < 5 { return .green }
        if stereo.phaseIssuePercentage < 20 { return .orange }
        return .red
    }

    private var phaseIcon: String {
        if stereo.phaseIssuePercentage < 5 { return "checkmark.circle.fill" }
        if stereo.phaseIssuePercentage < 20 { return "exclamationmark.triangle.fill" }
        return "xmark.circle.fill"
    }
}
