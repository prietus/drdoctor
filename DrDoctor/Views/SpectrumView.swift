import SwiftUI
import Charts

struct SpectrumView: View {
    let spectrumData: SpectrumData
    let spectralResult: SpectralResult
    let sampleRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Frequency Spectrum", systemImage: "chart.xyaxis.line")
                    .font(.headline)

                Spacer()

                if spectralResult.isSuspiciousUpconvert, let cutoff = spectralResult.detectedCutoffHz {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(String(format: "Cutoff: %.0f Hz", cutoff))
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                }
            }

            GeometryReader { geo in
                Canvas { context, size in
                    let width = size.width
                    let height = size.height
                    let count = spectrumData.magnitudes.count
                    guard count > 1 else { return }

                    let nyquist = Float(sampleRate / 2)
                    let minFreqLog = log10(Float(20))
                    let maxFreqLog = log10(nyquist)
                    let freqRange = maxFreqLog - minFreqLog

                    // Fixed dB range for consistent display
                    let displayMax: Float = 0
                    let displayMin: Float = -90

                    func freqToX(_ freq: Float) -> CGFloat {
                        guard freq > 0 else { return 0 }
                        return CGFloat((log10(freq) - minFreqLog) / freqRange) * width
                    }

                    func dbToY(_ db: Float) -> CGFloat {
                        let clamped = max(displayMin, min(displayMax, db))
                        return height * CGFloat(1.0 - (clamped - displayMin) / (displayMax - displayMin))
                    }

                    // Draw grid lines (dB)
                    for db: Float in stride(from: -80, through: 0, by: 20) {
                        let y = dbToY(db)
                        var gridLine = Path()
                        gridLine.move(to: CGPoint(x: 0, y: y))
                        gridLine.addLine(to: CGPoint(x: width, y: y))
                        context.stroke(gridLine, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

                        context.draw(
                            Text("\(Int(db)) dB").font(.system(size: 9)).foregroundStyle(.secondary),
                            at: CGPoint(x: 28, y: y - 7)
                        )
                    }

                    // Draw frequency markers
                    let freqMarkers: [Float] = [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
                    for freq in freqMarkers {
                        let x = freqToX(freq)
                        if x > 5 && x < width - 5 {
                            var freqLine = Path()
                            freqLine.move(to: CGPoint(x: x, y: 0))
                            freqLine.addLine(to: CGPoint(x: x, y: height))
                            context.stroke(freqLine, with: .color(.white.opacity(0.06)), lineWidth: 0.5)

                            let label = freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
                            context.draw(
                                Text(label).font(.system(size: 8)).foregroundStyle(.tertiary),
                                at: CGPoint(x: x, y: height - 7)
                            )
                        }
                    }

                    // Build spectrum path with filled area
                    var linePath = Path()
                    var fillPath = Path()
                    var started = false

                    for i in 0..<count {
                        let freq = spectrumData.frequencies[i]
                        guard freq >= 20 && freq <= nyquist else { continue }

                        let x = freqToX(freq)
                        let y = dbToY(spectrumData.magnitudes[i])

                        if !started {
                            linePath.move(to: CGPoint(x: x, y: y))
                            fillPath.move(to: CGPoint(x: x, y: height))
                            fillPath.addLine(to: CGPoint(x: x, y: y))
                            started = true
                        } else {
                            linePath.addLine(to: CGPoint(x: x, y: y))
                            fillPath.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    // Close fill path
                    if started, let lastFreq = spectrumData.frequencies.last {
                        let lastX = freqToX(min(lastFreq, nyquist))
                        fillPath.addLine(to: CGPoint(x: lastX, y: height))
                        fillPath.closeSubpath()
                    }

                    // Draw filled area with gradient
                    let gradient = Gradient(colors: [
                        .cyan.opacity(0.3),
                        .blue.opacity(0.1),
                        .clear
                    ])
                    context.fill(
                        fillPath,
                        with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height))
                    )

                    // Draw line
                    context.stroke(linePath, with: .color(.cyan), lineWidth: 1.5)

                    // Draw cutoff marker if detected
                    if let cutoff = spectrumData.cutoffMarker, cutoff > 20 {
                        let x = freqToX(cutoff)
                        var cutoffLine = Path()
                        cutoffLine.move(to: CGPoint(x: x, y: 0))
                        cutoffLine.addLine(to: CGPoint(x: x, y: height))
                        context.stroke(
                            cutoffLine,
                            with: .color(.red.opacity(0.8)),
                            style: StrokeStyle(lineWidth: 2, dash: [5, 3])
                        )
                        context.draw(
                            Text(String(format: "%.0f Hz", cutoff))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.red),
                            at: CGPoint(x: x + 30, y: 14)
                        )
                    }
                }
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 220)
        }
    }
}
