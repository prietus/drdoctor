import SwiftUI

struct VerdictBadgeView: View {
    let verdict: MasteringVerdictResult

    var body: some View {
        VStack(spacing: 16) {
            // Main verdict badge
            HStack(spacing: 12) {
                Image(systemName: verdictIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(verdictColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict.overall.rawValue)
                        .font(.title2.bold())
                        .foregroundStyle(verdictColor)

                    Text(verdictSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(verdictColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(verdictColor.opacity(0.3), lineWidth: 1)
            )

            // Detail items
            VStack(spacing: 8) {
                ForEach(Array(verdict.details.enumerated()), id: \.offset) { _, detail in
                    detailRow(detail)
                }
            }
        }
    }

    private func detailRow(_ detail: VerdictDetail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(detail.status))
                .foregroundStyle(statusColor(detail.status))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(detail.category)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(detail.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusColor(detail.status).opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var verdictIcon: String {
        switch verdict.overall {
        case .excellent: return "checkmark.seal.fill"
        case .good: return "hand.thumbsup.fill"
        case .mediocre: return "exclamationmark.circle.fill"
        case .poor: return "xmark.octagon.fill"
        case .suspicious: return "questionmark.diamond.fill"
        }
    }

    private var verdictColor: Color {
        switch verdict.overall {
        case .excellent: return .green
        case .good: return .blue
        case .mediocre: return .orange
        case .poor: return .red
        case .suspicious: return .purple
        }
    }

    private var verdictSubtitle: String {
        switch verdict.overall {
        case .excellent: return "This track has been carefully mastered with excellent dynamics."
        case .good: return "Solid mastering with good balance between loudness and dynamics."
        case .mediocre: return "Mastering shows signs of over-compression. Could be better."
        case .poor: return "Heavy compression and clipping. Typical loudness war casualty."
        case .suspicious: return "This file may have been upconverted from a lossy source."
        }
    }

    private func statusIcon(_ status: VerdictStatus) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: VerdictStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }
}
