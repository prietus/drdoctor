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

        // DSD to PCM via 5th-order CIC (Cascaded Integrator-Comb) decimation filter.
        // CIC is the standard approach for DSD→PCM: operates directly on the 1-bit stream,
        // provides >100dB stopband rejection, and preserves signal level correctly.
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

        // 5th-order CIC decimation filter
        // Integrator stages accumulate, comb stages differentiate after decimation.
        // This provides sinc^5 frequency response with excellent stopband rejection.
        let cicOrder = 5
        var integrators = [Int64](repeating: 0, count: cicOrder)
        var combPrev = [Int64](repeating: 0, count: cicOrder)

        let totalDSDBits = ch0Bytes.count * 8
        let outputSamples = min(totalDSDBits / R, maxPCMSamples)
        guard outputSamples > 0 else {
            throw AudioReaderError.dsfParseError("Could not decode any samples")
        }

        var monoSamples = [Float](repeating: 0, count: outputSamples)

        // CIC gain = R^N. Use Double to avoid overflow issues.
        let cicGain = pow(Double(R), Double(cicOrder))
        let invGain = Float(1.0 / cicGain)

        var bitCounter = 0
        var sampleIdx = 0

        for byte in ch0Bytes {
            // DSF stores LSB first within each byte
            for bitPos in 0..<8 {
                let bit = Int64((byte >> bitPos) & 1)
                let x: Int64 = bit == 1 ? 1 : -1

                // Integrator stages (recursive accumulation)
                integrators[0] += x
                for s in 1..<cicOrder {
                    integrators[s] += integrators[s - 1]
                }

                bitCounter += 1
                if bitCounter == R {
                    // Comb stages (differencing with delay)
                    var combIn = integrators[cicOrder - 1]
                    for s in 0..<cicOrder {
                        let delayed = combPrev[s]
                        combPrev[s] = combIn
                        combIn = combIn - delayed
                    }

                    if sampleIdx < outputSamples {
                        monoSamples[sampleIdx] = Float(combIn) * invGain
                        sampleIdx += 1
                    }
                    bitCounter = 0
                }
            }
            if sampleIdx >= outputSamples { break }
        }

        // CIC compensation FIR: correct the passband droop (sinc^N rolloff).
        // Short 32-tap inverse-sinc filter, Hann-windowed, cutoff at 20kHz.
        let compFilterLen = 32
        var compFilter = [Float](repeating: 0, count: compFilterLen)
        let compCenter = Float(compFilterLen - 1) / 2.0
        let compCutoff = Float(20000.0 / pcmSampleRate) * 2.0

        for i in 0..<compFilterLen {
            let n = Float(i) - compCenter
            // Base sinc
            let sinc: Float
            if abs(n) < 0.0001 {
                sinc = compCutoff
            } else {
                sinc = sin(Float.pi * compCutoff * n) / (Float.pi * n)
            }
            // Hann window
            let w = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(compFilterLen - 1)))

            // Inverse-sinc compensation: boost frequencies the CIC attenuated
            // CIC response ≈ sinc(f/fs * R), so compensation ≈ 1/sinc(f) at each tap
            let fNorm = Float(n) / Float(R)
            let cicResponse: Float
            if abs(fNorm) < 0.0001 {
                cicResponse = 1.0
            } else {
                cicResponse = sin(Float.pi * fNorm) / (Float.pi * fNorm)
            }
            let compensation = abs(cicResponse) > 0.1 ? 1.0 / abs(cicResponse) : 1.0

            compFilter[i] = sinc * w * min(compensation, 3.0) // cap compensation at 3x
        }

        // Normalize compensation filter
        let compSum = compFilter.reduce(0, +)
        if compSum > 0 {
            for i in 0..<compFilterLen { compFilter[i] /= compSum }
        }

        // Apply compensation filter (no decimation, stride=1)
        let compensatedCount = outputSamples - compFilterLen
        guard compensatedCount > 0 else {
            throw AudioReaderError.dsfParseError("Not enough samples for compensation filter")
        }
        var compensated = [Float](repeating: 0, count: compensatedCount)
        vDSP_desamp(monoSamples, 1, compFilter, &compensated, vDSP_Length(compensatedCount), vDSP_Length(compFilterLen))

        let duration = Double(sampleCount) / dsdSampleRate

        return AudioData(
            samples: compensated,
            leftChannel: nil, // DSF: mono analysis only (ch0)
            rightChannel: nil,
            sampleRate: pcmSampleRate,
            channels: channelCount,
            bitDepth: bitsPerSample > 0 ? bitsPerSample : 1,
            codec: "DSD\(Int(dsdSampleRate / 44100)) (DSF)",
            duration: duration
        )
    }
}
