import SwiftUI

struct ComparisonData {
    let editionA: EditionData
    let editionB: EditionData
}

struct EditionData {
    let name: String
    let tracks: [TrackSummary]
    let summary: AlbumSummary
}

struct ComparisonView: View {
    let data: ComparisonData
    let onSelectTrack: (AudioAnalysis) -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                summaryComparison
                trackComparison
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(data.editionA.name)
                        .font(.title3.bold())
                        .foregroundStyle(.cyan)
                    Text("vs")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(data.editionB.name)
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 16) {
                    Text("\(data.editionA.summary.trackCount) tracks")
                        .foregroundStyle(.cyan.opacity(0.7))
                    Text("\(data.editionB.summary.trackCount) tracks")
                        .foregroundStyle(.orange.opacity(0.7))
                }
                .font(.caption)
            }

            Spacer()

            Button { onBack() } label: {
                Label("New Analysis", systemImage: "arrow.left.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Summary Comparison

    private var summaryComparison: some View {
        let a = data.editionA.summary
        let b = data.editionB.summary

        return LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()),
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            comparisonCard(title: "Avg DR",
                           valueA: String(format: "DR%.0f", a.avgDR),
                           valueB: String(format: "DR%.0f", b.avgDR),
                           aWins: a.avgDR > b.avgDR)

            comparisonCard(title: "Avg LUFS",
                           valueA: String(format: "%.1f", a.avgLUFS),
                           valueB: String(format: "%.1f", b.avgLUFS),
                           aWins: a.avgLUFS < b.avgLUFS) // lower LUFS = more dynamic

            comparisonCard(title: "Max Peak",
                           valueA: String(format: "%.1f", a.maxTruePeak),
                           valueB: String(format: "%.1f", b.maxTruePeak),
                           aWins: a.maxTruePeak < b.maxTruePeak) // lower peak = more headroom

            comparisonCard(title: "Verdict",
                           valueA: shortVerdict(a.overallVerdict),
                           valueB: shortVerdict(b.overallVerdict),
                           aWins: verdictScore(a.overallVerdict) > verdictScore(b.overallVerdict))
        }
    }

    private func comparisonCard(title: String, valueA: String, valueB: String, aWins: Bool) -> some View {
        let tie = valueA == valueB
        return VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(valueA)
                    .font(.headline.monospacedDigit())
                    .foregroundColor(tie ? .primary : (aWins ? .green : .secondary))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("vs")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)

                Text(valueB)
                    .font(.headline.monospacedDigit())
                    .foregroundColor(tie ? .primary : (aWins ? .secondary : .green))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Track Comparison Table

    private var trackComparison: some View {
        let maxTracks = max(data.editionA.tracks.count, data.editionB.tracks.count)

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text("#").frame(width: 30)
                Text("Track").frame(maxWidth: .infinity, alignment: .leading)
                // Edition A columns
                Text("DR").frame(width: 40)
                Text("LUFS").frame(width: 50)
                Text("Peak").frame(width: 45)
                // Deltas
                Text("Δ").frame(width: 30)
                Text("Δ").frame(width: 35)
                // Edition B columns
                Text("DR").frame(width: 40)
                Text("LUFS").frame(width: 50)
                Text("Peak").frame(width: 45)
            }
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))

            // Column edition labels
            HStack(spacing: 0) {
                Text("").frame(width: 30)
                Text("Click values to see track detail").font(.system(size: 8)).foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A
                Text("A").foregroundStyle(.cyan).frame(width: 40)
                Text("A").foregroundStyle(.cyan).frame(width: 50)
                Text("A").foregroundStyle(.cyan).frame(width: 45)
                // Deltas
                Text("").frame(width: 30)
                Text("").frame(width: 35)
                // B
                Text("B").foregroundStyle(.orange).frame(width: 40)
                Text("B").foregroundStyle(.orange).frame(width: 50)
                Text("B").foregroundStyle(.orange).frame(width: 45)
            }
            .font(.system(size: 9).bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            Divider()

            // Track rows
            ForEach(0..<maxTracks, id: \.self) { index in
                let trackA = index < data.editionA.tracks.count ? data.editionA.tracks[index] : nil
                let trackB = index < data.editionB.tracks.count ? data.editionB.tracks[index] : nil
                let trackName = trackA?.fileName ?? trackB?.fileName ?? "—"

                HStack(spacing: 0) {
                    Text("\(index + 1)")
                        .frame(width: 30)
                        .foregroundStyle(.secondary)

                    Text(trackName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Edition A values (clickable → track A detail)
                    HStack(spacing: 0) {
                        drCell(trackA?.analysis.dynamicRange.drScore).frame(width: 40)
                        lufsCell(trackA?.analysis.dynamicRange.integratedLUFS).frame(width: 50)
                        peakCell(trackA?.analysis.clipping.truePeakDB).frame(width: 45)
                    }
                    .foregroundStyle(.cyan)
                    .contentShape(Rectangle())
                    .onTapGesture { if let a = trackA { onSelectTrack(a.analysis) } }
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    // Deltas
                    deltaCell(
                        a: trackA?.analysis.dynamicRange.drScore,
                        b: trackB?.analysis.dynamicRange.drScore,
                        higherIsBetter: true
                    ).frame(width: 30)
                    deltaCell(
                        a: trackA?.analysis.dynamicRange.integratedLUFS,
                        b: trackB?.analysis.dynamicRange.integratedLUFS,
                        higherIsBetter: false
                    ).frame(width: 35)

                    // Edition B values (clickable → track B detail)
                    HStack(spacing: 0) {
                        drCell(trackB?.analysis.dynamicRange.drScore).frame(width: 40)
                        lufsCell(trackB?.analysis.dynamicRange.integratedLUFS).frame(width: 50)
                        peakCell(trackB?.analysis.clipping.truePeakDB).frame(width: 45)
                    }
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                    .onTapGesture { if let b = trackB { onSelectTrack(b.analysis) } }
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

                Divider().opacity(0.3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Cell Helpers

    private func drCell(_ value: Double?) -> Text {
        guard let v = value else { return Text("—") }
        return Text(String(format: "%.0f", v))
    }

    private func lufsCell(_ value: Double?) -> Text {
        guard let v = value else { return Text("—") }
        return Text(String(format: "%.1f", v))
    }

    private func peakCell(_ value: Double?) -> Text {
        guard let v = value else { return Text("—") }
        return Text(String(format: "%.1f", v))
    }

    private func deltaCell(a: Double?, b: Double?, higherIsBetter: Bool) -> some View {
        guard let a = a, let b = b else {
            return Text("—").foregroundStyle(.quaternary)
        }
        let diff = a - b
        if abs(diff) < 0.1 {
            return Text("=").foregroundStyle(.secondary)
        }
        let aWins = higherIsBetter ? diff > 0 : diff < 0
        let prefix = diff > 0 ? "+" : ""
        return Text("\(prefix)\(String(format: "%.0f", diff))")
            .foregroundStyle(aWins ? .green : .red)
    }

    // MARK: - Helpers

    private func shortVerdict(_ v: MasteringVerdict) -> String {
        switch v {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .mediocre: return "Mediocre"
        case .poor: return "Poor"
        case .suspicious: return "Suspect"
        }
    }

    private func verdictScore(_ v: MasteringVerdict) -> Int {
        switch v {
        case .excellent: return 4
        case .good: return 3
        case .mediocre: return 2
        case .poor: return 1
        case .suspicious: return 0
        }
    }
}
