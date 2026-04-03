import SwiftUI

struct WaveformView: View {
    let waveform: WaveformData
    let clipping: ClippingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waveform", systemImage: "waveform")
                .font(.headline)

            GeometryReader { geo in
                Canvas { context, size in
                    let width = size.width
                    let height = size.height
                    let midY = height / 2
                    let count = waveform.maxSamples.count
                    guard count > 0 else { return }

                    let stepX = width / CGFloat(count)

                    // Draw waveform envelope
                    var envelopePath = Path()
                    // Top half (max values)
                    for i in 0..<count {
                        let x = CGFloat(i) * stepX
                        let y = midY - CGFloat(waveform.maxSamples[i]) * midY
                        if i == 0 {
                            envelopePath.move(to: CGPoint(x: x, y: y))
                        } else {
                            envelopePath.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    // Bottom half (min values, reversed)
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        let x = CGFloat(i) * stepX
                        let y = midY - CGFloat(waveform.minSamples[i]) * midY
                        envelopePath.addLine(to: CGPoint(x: x, y: y))
                    }
                    envelopePath.closeSubpath()

                    // Color gradient based on level
                    let gradient = Gradient(colors: [
                        .green.opacity(0.6),
                        .yellow.opacity(0.6),
                        .red.opacity(0.6)
                    ])
                    context.fill(
                        envelopePath,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: height),
                            endPoint: CGPoint(x: 0, y: 0)
                        )
                    )

                    // Draw RMS envelope
                    var rmsTop = Path()
                    var rmsBottom = Path()
                    for i in 0..<count {
                        let x = CGFloat(i) * stepX
                        let rmsY = CGFloat(waveform.rmsEnvelope[i]) * midY
                        let topY = midY - rmsY
                        let bottomY = midY + rmsY
                        if i == 0 {
                            rmsTop.move(to: CGPoint(x: x, y: topY))
                            rmsBottom.move(to: CGPoint(x: x, y: bottomY))
                        } else {
                            rmsTop.addLine(to: CGPoint(x: x, y: topY))
                            rmsBottom.addLine(to: CGPoint(x: x, y: bottomY))
                        }
                    }
                    context.stroke(rmsTop, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
                    context.stroke(rmsBottom, with: .color(.white.opacity(0.4)), lineWidth: 0.5)

                    // Center line
                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: midY))
                    centerLine.addLine(to: CGPoint(x: width, y: midY))
                    context.stroke(centerLine, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

                    // 0dBFS lines
                    let clipColor: Color = clipping.clippingPercentage > 0.1 ? .red : .white.opacity(0.15)
                    var topClipLine = Path()
                    topClipLine.move(to: CGPoint(x: 0, y: 0))
                    topClipLine.addLine(to: CGPoint(x: width, y: 0))
                    context.stroke(topClipLine, with: .color(clipColor), lineWidth: 1)

                    var bottomClipLine = Path()
                    bottomClipLine.move(to: CGPoint(x: 0, y: height))
                    bottomClipLine.addLine(to: CGPoint(x: width, y: height))
                    context.stroke(bottomClipLine, with: .color(clipColor), lineWidth: 1)
                }
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 180)
        }
    }
}
