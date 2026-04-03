import SwiftUI

struct TrackSummary: Identifiable {
    let id = UUID()
    let trackNumber: Int
    let fileName: String
    let url: URL
    let analysis: AudioAnalysis
}

struct AlbumSummary {
    let folderName: String
    let trackCount: Int
    let avgDR: Double
    let avgLUFS: Double
    let maxTruePeak: Double
    let worstClipping: Double
    let overallVerdict: MasteringVerdict
}

struct FolderAnalysisView: View {
    let tracks: [TrackSummary]
    let albumSummary: AlbumSummary
    let onSelectTrack: (AudioAnalysis) -> Void
    let onBack: () -> Void

    @State private var sortOrder: SortOrder = .trackNumber
    @State private var selectedTrackID: UUID?

    enum SortOrder {
        case trackNumber, dr, lufs, peak, clipping
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                albumSummarySection
                trackTable
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(albumSummary.folderName)
                    .font(.title2.bold())
                Text("\(albumSummary.trackCount) tracks analyzed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onBack()
            } label: {
                Label("New Analysis", systemImage: "arrow.left.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Album Summary

    private var albumSummarySection: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Avg DR", value: String(format: "DR%.0f", albumSummary.avgDR),
                        color: albumSummary.avgDR >= 10 ? .green : albumSummary.avgDR >= 6 ? .orange : .red)
            summaryCard(title: "Avg LUFS", value: String(format: "%.1f", albumSummary.avgLUFS),
                        color: albumSummary.avgLUFS < -10 ? .green : albumSummary.avgLUFS < -7 ? .orange : .red)
            summaryCard(title: "Max Peak", value: String(format: "%.1f dBTP", albumSummary.maxTruePeak),
                        color: albumSummary.maxTruePeak <= -1 ? .green : .red)
            summaryCard(title: "Verdict", value: shortVerdict(albumSummary.overallVerdict),
                        color: verdictColor(albumSummary.overallVerdict))
        }
    }

    private func summaryCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Track Table

    private var trackTable: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                headerCell("#", width: 35, sortKey: .trackNumber)
                headerCell("Track", width: nil, sortKey: .trackNumber)
                headerCell("DR", width: 60, sortKey: .dr)
                headerCell("LUFS", width: 70, sortKey: .lufs)
                headerCell("Peak", width: 70, sortKey: .peak)
                headerCell("Clip", width: 80, sortKey: .clipping)
                headerCell("Verdict", width: 90, sortKey: .trackNumber)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Track rows
            ForEach(sortedTracks) { track in
                Button {
                    onSelectTrack(track.analysis)
                } label: {
                    HStack(spacing: 0) {
                        Text("\(track.trackNumber)")
                            .frame(width: 35, alignment: .center)
                            .foregroundStyle(.secondary)

                        Text(track.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(String(format: "DR%.0f", track.analysis.dynamicRange.drScore))
                            .frame(width: 60)
                            .foregroundStyle(drColor(track.analysis.dynamicRange.drScore))

                        Text(String(format: "%.1f", track.analysis.dynamicRange.integratedLUFS))
                            .frame(width: 70)
                            .foregroundStyle(.secondary)

                        Text(String(format: "%.1f", track.analysis.clipping.truePeakDB))
                            .frame(width: 70)
                            .foregroundStyle(track.analysis.clipping.truePeakDB > -1 ? .red : .secondary)

                        Text(track.analysis.clipping.clippingRating.rawValue)
                            .frame(width: 80)
                            .foregroundStyle(clipColor(track.analysis.clipping.clippingRating))

                        Image(systemName: verdictIcon(track.analysis.verdict.overall))
                            .frame(width: 90)
                            .foregroundStyle(verdictColor(track.analysis.verdict.overall))
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : Color.clear
                    )
                }
                .buttonStyle(.plain)

                Divider().opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    private func headerCell(_ title: String, width: CGFloat?, sortKey: SortOrder) -> some View {
        Button {
            sortOrder = sortKey
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortOrder == sortKey {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: width == nil ? .leading : .center)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var sortedTracks: [TrackSummary] {
        switch sortOrder {
        case .trackNumber: return tracks.sorted { $0.trackNumber < $1.trackNumber }
        case .dr: return tracks.sorted { $0.analysis.dynamicRange.drScore > $1.analysis.dynamicRange.drScore }
        case .lufs: return tracks.sorted { $0.analysis.dynamicRange.integratedLUFS < $1.analysis.dynamicRange.integratedLUFS }
        case .peak: return tracks.sorted { $0.analysis.clipping.truePeakDB > $1.analysis.clipping.truePeakDB }
        case .clipping: return tracks.sorted { $0.analysis.clipping.clippingPercentage > $1.analysis.clipping.clippingPercentage }
        }
    }

    // MARK: - Helpers

    private func drColor(_ dr: Double) -> Color {
        if dr >= 14 { return .green }
        if dr >= 10 { return .blue }
        if dr >= 6 { return .orange }
        return .red
    }

    private func clipColor(_ rating: ClippingRating) -> Color {
        switch rating {
        case .none: return .green
        case .minimal: return .blue
        case .moderate: return .orange
        case .severe: return .red
        }
    }

    private func verdictColor(_ verdict: MasteringVerdict) -> Color {
        switch verdict {
        case .excellent: return .green
        case .good: return .blue
        case .mediocre: return .orange
        case .poor: return .red
        case .suspicious: return .purple
        }
    }

    private func verdictIcon(_ verdict: MasteringVerdict) -> String {
        switch verdict {
        case .excellent: return "checkmark.seal.fill"
        case .good: return "hand.thumbsup.fill"
        case .mediocre: return "exclamationmark.circle.fill"
        case .poor: return "xmark.octagon.fill"
        case .suspicious: return "questionmark.diamond.fill"
        }
    }

    private func shortVerdict(_ verdict: MasteringVerdict) -> String {
        switch verdict {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .mediocre: return "Mediocre"
        case .poor: return "Poor"
        case .suspicious: return "Suspect"
        }
    }
}
