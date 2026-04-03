import Foundation

struct AudioFileInfo {
    let url: URL
    let fileName: String
    let fileExtension: String
    let fileSize: Int64
    let sampleRate: Double
    let bitDepth: Int
    let channels: Int
    let duration: TimeInterval
    let codec: String

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var sampleRateFormatted: String {
        if sampleRate >= 1000 {
            return String(format: "%.1f kHz", sampleRate / 1000)
        }
        return "\(Int(sampleRate)) Hz"
    }
}
