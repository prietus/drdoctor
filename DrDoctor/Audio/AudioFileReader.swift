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
    let leftChannel: [Float]?
    let rightChannel: [Float]?
    let sampleRate: Double
    let originalSampleRate: Double  // For DSD: the native rate (2822400 etc), for PCM: same as sampleRate
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

        // Preserve individual channels for stereo analysis
        var leftChannel: [Float]?
        var rightChannel: [Float]?

        if channelCount >= 2,
           let leftData = buffer.floatChannelData?[0],
           let rightData = buffer.floatChannelData?[1] {
            leftChannel = Array(UnsafeBufferPointer(start: leftData, count: sampleCount))
            rightChannel = Array(UnsafeBufferPointer(start: rightData, count: sampleCount))
        }

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
            leftChannel: leftChannel,
            rightChannel: rightChannel,
            sampleRate: file.processingFormat.sampleRate,
            originalSampleRate: file.processingFormat.sampleRate,
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
        // DSF fmt chunk layout (offsets relative to fmt start):
        // +12: format version (uint32)   +16: format ID (uint32)
        // +20: channel type (uint32)     +24: channel count (uint32)
        // +28: sample rate (uint32)      +32: bits per sample (uint32)
        // +36: sample count (uint64)     +44: block size per channel (uint32)
        let channelCount: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 24, as: UInt32.self).littleEndian)
        }
        let dsdSampleRate: Double = headerData.withUnsafeBytes {
            Double($0.loadUnaligned(fromByteOffset: fmtOffset + 28, as: UInt32.self).littleEndian)
        }
        let bitsPerSample: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 32, as: UInt32.self).littleEndian)
        }
        let sampleCount: UInt64 = headerData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: fmtOffset + 36, as: UInt64.self).littleEndian
        }
        let blockSizePerChannel: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: fmtOffset + 44, as: UInt32.self).littleEndian)
        }

        // data chunk: right after fmt
        let dataChunkOffset = fmtOffset + fmtChunkSize
        guard dataChunkOffset + 12 <= headerData.count,
              String(data: headerData[dataChunkOffset..<(dataChunkOffset + 4)], encoding: .ascii) == "data" else {
            throw AudioReaderError.dsfParseError("Invalid data chunk")
        }
        let dataPayloadOffset = dataChunkOffset + 12

        let blockSize = blockSizePerChannel > 0 ? blockSizePerChannel : 4096
        let interleaveBlockSize = blockSize * channelCount
        let availableDataBytes = totalFileSize - dataPayloadOffset

        let totalBlocks = availableDataBytes / interleaveBlockSize
        guard totalBlocks > 0 else {
            throw AudioReaderError.dsfParseError("No audio data to decode")
        }

        let pcmSampleRate = 44100.0
        // Decimation ratio: DSD64=64, DSD128=128, DSD256=256
        let R = Int(dsdSampleRate / pcmSampleRate)
        guard R > 0 else {
            throw AudioReaderError.dsfParseError("Invalid DSD sample rate for decimation")
        }

        // Calculate how many ch0 bytes we need for ~30s of output
        let maxPCMSamples = Int(pcmSampleRate * 30)
        let dsdBitsNeeded = maxPCMSamples * R
        let ch0BytesNeeded = (dsdBitsNeeded + 7) / 8
        let blocksNeeded = min((ch0BytesNeeded + blockSize - 1) / blockSize, totalBlocks)

        // ONE sequential read from data start
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

        // Two-stage DSD→PCM decimation (fast + accurate):
        // Stage 1: byte-level popcount → intermediate rate (1 byte = 1 sample at DSD_rate/8)
        // Stage 2: FIR decimation with vDSP → 44.1kHz output
        //
        // This matches CIC quality while being ~50x faster than bit-by-bit processing.

        // Popcount lookup table
        var popcountTable = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            var count: UInt8 = 0
            var val = i
            while val != 0 { count += 1; val &= val - 1 }
            popcountTable[i] = count
        }

        // Stage 1: each byte → one intermediate sample (DSD_rate/8 Hz)
        let intermediateSampleRate = dsdSampleRate / 8.0
        let intermediateCount = ch0Bytes.count
        var intermediate = [Float](repeating: 0, count: intermediateCount)

        ch0Bytes.withUnsafeBufferPointer { ptr in
            for i in 0..<intermediateCount {
                // Map 0..8 ones to -1..+1
                intermediate[i] = Float(popcountTable[Int(ptr[i])]) * 0.25 - 1.0
            }
        }

        // Stage 2: FIR decimation from intermediate rate to 44.1kHz
        let stage2R = Int(intermediateSampleRate / pcmSampleRate) // 8 for DSD64, 32 for DSD256
        guard stage2R > 0 else {
            throw AudioReaderError.dsfParseError("Invalid stage-2 decimation ratio")
        }

        // Design anti-aliasing FIR: 64-tap windowed-sinc at 20kHz / intermediateSampleRate
        let firLen = 64
        var firFilter = [Float](repeating: 0, count: firLen)
        let firCenter = Float(firLen - 1) / 2.0
        let firCutoff = Float(20000.0 / intermediateSampleRate) * 2.0

        for i in 0..<firLen {
            let n = Float(i) - firCenter
            let sinc: Float
            if abs(n) < 0.0001 {
                sinc = firCutoff
            } else {
                sinc = sin(Float.pi * firCutoff * n) / (Float.pi * n)
            }
            // Kaiser-like window for better stopband rejection
            let w = 0.42 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(firLen - 1))
                + 0.08 * cos(4.0 * Float.pi * Float(i) / Float(firLen - 1))
            firFilter[i] = sinc * w
        }
        // Normalize
        let firSum = firFilter.reduce(0, +)
        if firSum > 0 { for i in 0..<firLen { firFilter[i] /= firSum } }

        // Decimate with vDSP_desamp (applies FIR + downsamples in one pass)
        let outputSamples = min((intermediateCount - firLen) / stage2R, maxPCMSamples)
        guard outputSamples > 0 else {
            throw AudioReaderError.dsfParseError("Not enough data for decimation")
        }
        var compensated = [Float](repeating: 0, count: outputSamples)
        vDSP_desamp(intermediate, vDSP_Stride(stage2R), firFilter, &compensated,
                    vDSP_Length(outputSamples), vDSP_Length(firLen))

        let duration = Double(sampleCount) / dsdSampleRate

        return AudioData(
            samples: compensated,
            leftChannel: nil, // DSF: mono analysis only (ch0)
            rightChannel: nil,
            sampleRate: pcmSampleRate,
            originalSampleRate: dsdSampleRate,
            channels: channelCount,
            bitDepth: bitsPerSample > 0 ? bitsPerSample : 1,
            codec: "DSD\(Int(dsdSampleRate / 44100)) (DSF)",
            duration: duration
        )
    }
}
