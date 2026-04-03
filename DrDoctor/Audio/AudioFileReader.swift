import AVFoundation
import AVFoundation
import Accelerate

enum AudioReaderError: Error, LocalizedError {
    case fileNotFound
    case unsupportedFormat(String)
    case readError(String)
    case dsfParseError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "Audio file not found"
        case .unsupportedFormat(let fmt): return "Unsupported format: \(fmt)"
        case .readError(let msg): return "Read error: \(msg)"
        case .dsfParseError(let msg): return "DSF parse error: \(msg)"
        }
    }
}

struct AudioData {
    let samples: [Float]
    let sampleRate: Double
    let channels: Int
    let bitDepth: Int
    let codec: String
    let duration: TimeInterval
}

final class AudioFileReader {

    static func read(url: URL) async throws -> AudioData {
        let ext = url.pathExtension.lowercased()
        if ext == "dsf" || ext == "dff" {
            return try readDSF(url: url)
        }
        return try readWithAVFoundation(url: url)
    }

    // MARK: - AVFoundation Reader (WAV, FLAC, AIFF, ALAC, MP3, AAC, etc.)

    private static func readWithAVFoundation(url: URL) throws -> AudioData {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioReaderError.readError(error.localizedDescription)
        }

        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        )!

        // Cap to 30 seconds for analysis - no need to decode a full album track
        let maxFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 30)
        let frameCount = min(AVAudioFrameCount(file.length), maxFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw AudioReaderError.readError("Could not create audio buffer")
        }
        buffer.frameLength = frameCount

        try file.read(into: buffer, frameCount: frameCount)

        let channelCount = Int(processingFormat.channelCount)
        let sampleCount = Int(buffer.frameLength)

        // Mix to mono for analysis
        var monoSamples = [Float](repeating: 0, count: sampleCount)
        var scale = Float(1.0 / Double(channelCount))

        for ch in 0..<channelCount {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            vDSP_vsma(channelData, 1, &scale, monoSamples, 1, &monoSamples, 1, vDSP_Length(sampleCount))
        }

        let bitDepth = detectBitDepth(file: file)
        let codec = detectCodec(url: url, file: file)

        return AudioData(
            samples: monoSamples,
            sampleRate: file.processingFormat.sampleRate,
            channels: channelCount,
            bitDepth: bitDepth,
            codec: codec,
            duration: Double(file.length) / file.processingFormat.sampleRate
        )
    }

    private static func detectBitDepth(file: AVAudioFile) -> Int {
        let settings = file.fileFormat.settings
        if let depth = settings[AVLinearPCMBitDepthKey] as? Int {
            return depth
        }
        switch file.processingFormat.commonFormat {
        case .pcmFormatFloat32: return 32
        case .pcmFormatFloat64: return 64
        case .pcmFormatInt16: return 16
        case .pcmFormatInt32: return 32
        default: return 16
        }
    }

    private static func detectCodec(url: URL, file: AVAudioFile) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav": return "PCM/WAV"
        case "flac": return "FLAC"
        case "aif", "aiff": return "AIFF"
        case "alac": return "ALAC"
        case "m4a":
            let settings = file.fileFormat.settings
            if let formatID = settings[AVFormatIDKey] as? UInt32 {
                if formatID == kAudioFormatAppleLossless { return "ALAC" }
                if formatID == kAudioFormatMPEG4AAC { return "AAC" }
            }
            return "M4A"
        case "mp3": return "MP3"
        case "aac": return "AAC"
        case "ogg": return "OGG Vorbis"
        default: return ext.uppercased()
        }
    }

    // MARK: - DSF/DSD Reader

    private static func readDSF(url: URL) throws -> AudioData {
        let fh = try FileHandle(forReadingFrom: url)
        defer { fh.closeFile() }

        // Read ONLY the header - 512 bytes max (DSD chunk=28 + fmt chunk~52 + data chunk header=12)
        guard let headerData = try fh.read(upToCount: 512), headerData.count >= 92 else {
            throw AudioReaderError.dsfParseError("File too small or unreadable")
        }

        // DSD chunk: bytes 0..27
        guard String(data: headerData[0..<4], encoding: .ascii) == "DSD " else {
            throw AudioReaderError.dsfParseError("Invalid DSD header")
        }
        // Total file size is at offset 12 (uint64 LE) - avoids seekToEndOfFile!
        let totalFileSize: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: 12, as: UInt64.self).littleEndian)
        }

        // fmt chunk: always at offset 28
        let fmtOffset = 28
        guard String(data: headerData[fmtOffset..<(fmtOffset + 4)], encoding: .ascii) == "fmt " else {
            throw AudioReaderError.dsfParseError("Invalid fmt chunk")
        }

        let fmtChunkSize: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 4, as: UInt64.self).littleEndian)
        }
        let channelCount: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 20, as: UInt32.self).littleEndian)
        }
        let dsdSampleRate: Double = headerData.withUnsafeBytes {
            Double($0.loadUnaligned(fromByteOffset: fmtOffset + 24, as: UInt32.self).littleEndian)
        }
        let bitsPerSample: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 28, as: UInt32.self).littleEndian)
        }
        let sampleCount: UInt64 = headerData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: fmtOffset + 32, as: UInt64.self).littleEndian
        }
        let blockSizePerChannel: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 40, as: UInt32.self).littleEndian)
        }

        // data chunk: right after fmt
        let dataChunkOffset = fmtOffset + fmtChunkSize
        guard dataChunkOffset + 12 <= headerData.count,
              String(data: headerData[dataChunkOffset..<(dataChunkOffset + 4)], encoding: .ascii) == "data" else {
            throw AudioReaderError.dsfParseError("Invalid data chunk")
        }
        let dataPayloadOffset = dataChunkOffset + 12

        // DSD to PCM: two-stage decimation with anti-aliasing filter
        // Stage 1: byte-level popcount → intermediate rate (dsdSampleRate / 8)
        // Stage 2: FIR low-pass filter + decimation → 44.1kHz
        let blockSize = blockSizePerChannel > 0 ? blockSizePerChannel : 4096
        let interleaveBlockSize = blockSize * channelCount
        let availableDataBytes = totalFileSize - dataPayloadOffset

        let totalBlocks = availableDataBytes / interleaveBlockSize
        guard totalBlocks > 0 else {
            throw AudioReaderError.dsfParseError("No audio data to decode")
        }

        // Intermediate rate: each byte → 1 sample at (dsdSampleRate / 8)
        // For DSD64: 2822400/8 = 352800 Hz
        let intermediateRate = dsdSampleRate / 8.0
        let pcmSampleRate = 44100.0
        let stage2Decimation = max(1, Int(intermediateRate / pcmSampleRate)) // 8 for DSD64

        // Calculate how many ch0 bytes we need for ~30s of output
        let maxPCMSamples = Int(pcmSampleRate * 30)
        let intermediateSamplesNeeded = maxPCMSamples * stage2Decimation
        let ch0BytesNeeded = intermediateSamplesNeeded
        let blocksNeeded = min((ch0BytesNeeded + blockSize - 1) / blockSize, totalBlocks)

        // ONE sequential read
        let bytesToRead = blocksNeeded * interleaveBlockSize
        try fh.seek(toOffset: UInt64(dataPayloadOffset))
        guard let rawData = try fh.read(upToCount: bytesToRead), !rawData.isEmpty else {
            throw AudioReaderError.dsfParseError("Could not read audio data")
        }

        // Extract ch0 bytes from interleaved blocks in memory
        var ch0Bytes = [UInt8]()
        ch0Bytes.reserveCapacity(blocksNeeded * blockSize)

        rawData.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var offset = 0
            while offset + interleaveBlockSize <= raw.count && ch0Bytes.count < ch0BytesNeeded {
                ch0Bytes.append(contentsOf: UnsafeBufferPointer(start: ptr + offset, count: blockSize))
                offset += interleaveBlockSize
            }
        }

        // Stage 1: popcount each byte → intermediate PCM at 352.8kHz (DSD64)
        let intermediateCount = ch0Bytes.count
        var intermediate = [Float](repeating: 0, count: intermediateCount)
        for i in 0..<intermediateCount {
            // Map byte popcount [0..8] → [-1.0..+1.0]
            intermediate[i] = Float(ch0Bytes[i].nonzeroBitCount) * 0.25 - 1.0
        }

        // Stage 2: FIR low-pass filter + decimation using vDSP
        // Design a simple 64-tap windowed sinc filter with cutoff at ~20kHz
        let filterLength = 64
        let cutoffNormalized = Float(20000.0 / intermediateRate) * 2.0 // normalized cutoff
        var firFilter = [Float](repeating: 0, count: filterLength)
        let center = Float(filterLength - 1) / 2.0

        for i in 0..<filterLength {
            let n = Float(i) - center
            // Sinc
            let sinc: Float
            if abs(n) < 0.0001 {
                sinc = cutoffNormalized
            } else {
                sinc = sin(Float.pi * cutoffNormalized * n) / (Float.pi * n)
            }
            // Hann window
            let window = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(filterLength - 1)))
            firFilter[i] = sinc * window
        }

        // Normalize filter
        let filterSum = firFilter.reduce(0, +)
        if filterSum > 0 {
            for i in 0..<filterLength {
                firFilter[i] /= filterSum
            }
        }

        // Apply FIR filter and decimate with vDSP_desamp
        let outputSamples = min((intermediateCount - filterLength) / stage2Decimation, maxPCMSamples)
        guard outputSamples > 0 else {
            throw AudioReaderError.dsfParseError("Could not decode any samples")
        }

        var monoSamples = [Float](repeating: 0, count: outputSamples)
        vDSP_desamp(intermediate, vDSP_Stride(stage2Decimation), firFilter,
                    &monoSamples, vDSP_Length(outputSamples), vDSP_Length(filterLength))

        // Normalize: DSD crude conversion produces very low levels.
        // Scale so peak reaches -1 dBFS (0.89), matching proper DSD-to-PCM converters.
        var peak: Float = 0
        vDSP_maxmgv(monoSamples, 1, &peak, vDSP_Length(outputSamples))
        if peak > 0.0001 {
            let targetPeak: Float = 0.89 // -1 dBFS
            var gain = targetPeak / peak
            vDSP_vsmul(monoSamples, 1, &gain, &monoSamples, 1, vDSP_Length(outputSamples))
        }

        let duration = Double(sampleCount) / dsdSampleRate

        return AudioData(
            samples: monoSamples,
            sampleRate: pcmSampleRate,
            channels: channelCount,
            bitDepth: bitsPerSample > 0 ? bitsPerSample : 1,
            codec: "DSD\(Int(dsdSampleRate / 44100)) (DSF)",
            duration: duration
        )
    }
}
