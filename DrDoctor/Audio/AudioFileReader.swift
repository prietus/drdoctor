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
    /// Mono mix of the first `AudioFileReader.excerptSeconds`, for spectrum/clipping/waveform.
    let samples: [Float]
    let leftChannel: [Float]?
    let rightChannel: [Float]?
    let sampleRate: Double
    let originalSampleRate: Double  // For DSD: the native rate (2822400 etc), for PCM: same as sampleRate
    let channels: Int
    let bitDepth: Int
    let codec: String
    let duration: TimeInterval
    /// DR14 measured over the whole track, every channel.
    let dr14: DR14Meter.Result
}

final class AudioFileReader {

    /// Length of the decoded excerpt kept for spectrum, stereo, clipping and waveform.
    /// DR is not limited by this: the whole file is streamed through `DR14Meter`.
    static let excerptSeconds = 30.0

    static func read(url: URL) async throws -> AudioData {
        let ext = url.pathExtension.lowercased()
        let isRemote = url.scheme == "http" || url.scheme == "https"

        if isRemote {
            // AVAssetReader/AVAudioFile only read local files, and DR14 needs every
            // sample anyway, so fetch the whole file to temp first.
            let localURL = try await downloadToTemp(url: url)
            defer { try? FileManager.default.removeItem(at: localURL) }
            if ext == "dsf" || ext == "dff" {
                return try readDSF(url: localURL)
            }
            return try readWithAVFoundation(url: localURL)
        }

        if ext == "dsf" || ext == "dff" {
            return try readDSF(url: url)
        }
        return try readWithAVFoundation(url: url)
    }

    // Extract credentials from URL and set Authorization header explicitly
    private static func addAuth(to request: inout URLRequest, from url: URL) {
        if let user = url.user, let pass = url.password {
            let cred = "\(user):\(pass)"
            if let data = cred.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
    }

    // Strip credentials from URL (URLSession can choke on embedded user:pass)
    private static func sanitizedURL(_ url: URL) -> URL {
        guard url.user != nil else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    // Whole file: DR14 needs every sample, so a partial download is not enough.
    private static func downloadToTemp(url: URL) async throws -> URL {
        var request = URLRequest(url: sanitizedURL(url), timeoutInterval: 120)
        request.httpMethod = "GET"
        addAuth(to: &request, from: url)
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            WebDAV.authorize(&request, for: url)
        }

        let (tempURL, response) = try await URLSession.shared.download(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            var root = URLComponents(url: sanitizedURL(url), resolvingAgainstBaseURL: false)
            root?.path = "/"
            throw WebDAVError.unauthorized(server: root?.url ?? url)
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw AudioReaderError.readError("HTTP \(http.statusCode) downloading \(url.lastPathComponent)")
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Mono mix plus L/R (when stereo or wider) from per-channel excerpt samples.
    private static func mixExcerpt(_ channels: [[Float]]) -> (mono: [Float], left: [Float]?, right: [Float]?) {
        let frameCount = channels.first?.count ?? 0
        var mono = [Float](repeating: 0, count: frameCount)
        var scale = Float(1.0 / Double(max(channels.count, 1)))
        for channel in channels {
            vDSP_vsma(channel, 1, &scale, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        guard channels.count >= 2 else { return (mono, nil, nil) }
        return (mono, channels[0], channels[1])
    }

    // MARK: - AVFoundation Reader (WAV, FLAC, AIFF, ALAC, MP3, AAC, etc.)

    private static func readWithAVFoundation(url: URL) throws -> AudioData {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioReaderError.readError(error.localizedDescription)
        }

        let format = file.processingFormat  // deinterleaved Float32
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let excerptFrames = Int(sampleRate * excerptSeconds)

        let chunkFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioReaderError.readError("Could not create audio buffer")
        }

        // Decode the whole file in chunks: every frame goes through the DR meter,
        // only the first `excerptSeconds` are kept for the other analyzers.
        var meter = DR14Meter(channelCount: channelCount, sampleRate: sampleRate)
        var excerpt = [[Float]](repeating: [], count: channelCount)
        for ch in 0..<channelCount { excerpt[ch].reserveCapacity(min(excerptFrames, Int(file.length))) }

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                // Some decoders overestimate `length`; stop at the real end once we have audio.
                if excerpt.first?.isEmpty ?? true { throw AudioReaderError.readError(error.localizedDescription) }
                break
            }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }

            meter.process(channels: (0..<channelCount).map { UnsafePointer(data[$0]) }, frames: n)

            let take = min(n, excerptFrames - excerpt[0].count)
            if take > 0 {
                for ch in 0..<channelCount {
                    excerpt[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: take))
                }
            }
        }

        let (mono, left, right) = mixExcerpt(excerpt)
        let bitDepth = detectBitDepth(file: file)
        let codec = detectCodec(url: url, file: file)

        return AudioData(
            samples: mono,
            leftChannel: left,
            rightChannel: right,
            sampleRate: sampleRate,
            originalSampleRate: sampleRate,
            channels: channelCount,
            bitDepth: bitDepth,
            codec: codec,
            duration: Double(file.length) / sampleRate,
            dr14: meter.finish()
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
        let dataChunkSize: Int = headerData.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: dataChunkOffset + 4, as: UInt64.self).littleEndian)
        }

        let blockSize = blockSizePerChannel > 0 ? blockSizePerChannel : 4096
        let channels = max(channelCount, 1)
        let interleaveBlockSize = blockSize * channels
        // The data chunk is followed by an ID3 metadata chunk, so bound by the chunk
        // size, not the file size. The file may also be shorter than declared.
        let actualFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? totalFileSize
        let availableDataBytes = min(dataChunkSize - 12, min(totalFileSize, actualFileSize) - dataPayloadOffset)
        let totalBlocks = availableDataBytes / interleaveBlockSize
        guard totalBlocks > 0 else {
            throw AudioReaderError.dsfParseError("No audio data to decode")
        }
        // The last block of each channel is zero-padded past `sampleCount` bits.
        let bytesPerChannel = min(Int((sampleCount + 7) / 8), totalBlocks * blockSize)

        let pcmSampleRate = 44100.0
        // Decimation ratio: DSD64=64, DSD128=128, DSD256=256
        guard Int(dsdSampleRate / pcmSampleRate) > 0 else {
            throw AudioReaderError.dsfParseError("Invalid DSD sample rate for decimation")
        }

        // Two-stage DSD→PCM decimation (fast + accurate):
        // Stage 1: byte-level popcount → intermediate rate (1 byte = 1 sample at DSD_rate/8)
        // Stage 2: FIR decimation with vDSP → 44.1kHz output
        var popcountTable = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            // Map 0..8 ones to -1..+1
            popcountTable[i] = Float(i.nonzeroBitCount) * 0.25 - 1.0
        }

        let intermediateSampleRate = dsdSampleRate / 8.0
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
            // Blackman window for better stopband rejection
            let w = 0.42 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(firLen - 1))
                + 0.08 * cos(4.0 * Float.pi * Float(i) / Float(firLen - 1))
            firFilter[i] = sinc * w
        }
        // Normalize
        let firSum = firFilter.reduce(0, +)
        if firSum > 0 { for i in 0..<firLen { firFilter[i] /= firSum } }

        // Decode the whole file, a group of interleaved blocks at a time. Each channel
        // keeps its unconsumed intermediate samples so the FIR runs seamlessly across reads.
        var meter = DR14Meter(channelCount: channels, sampleRate: pcmSampleRate)
        let excerptFrames = Int(pcmSampleRate * excerptSeconds)
        var excerpt = [[Float]](repeating: [], count: channels)
        var pending = [[Float]](repeating: [], count: channels)
        var channelBytesRead = 0
        var indices = [Float](repeating: 0, count: blockSize)
        let blocksPerRead = 64

        try fh.seek(toOffset: UInt64(dataPayloadOffset))
        var blocksLeft = totalBlocks
        while blocksLeft > 0, channelBytesRead < bytesPerChannel {
            let blocks = min(blocksPerRead, blocksLeft)
            guard let raw = try fh.read(upToCount: blocks * interleaveBlockSize), !raw.isEmpty else { break }
            let blocksRead = raw.count / interleaveBlockSize
            guard blocksRead > 0 else { break }
            blocksLeft -= blocksRead

            let usefulBytes = min(blocksRead * blockSize, bytesPerChannel - channelBytesRead)
            channelBytesRead += usefulBytes

            var pcm = [[Float]](repeating: [], count: channels)
            raw.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                for ch in 0..<channels {
                    // Stage 1: popcount this channel's bytes out of the interleaved blocks.
                    // Bytes become float indices into the table (vDSP_vfltu8 + vDSP_vindex)
                    // instead of a per-byte Swift loop.
                    let carried = pending[ch].count
                    pending[ch].append(contentsOf: repeatElement(0, count: usefulBytes))
                    indices.withUnsafeMutableBufferPointer { idx in
                        pending[ch].withUnsafeMutableBufferPointer { dst in
                            var copied = 0
                            var block = 0
                            while copied < usefulBytes {
                                let n = min(blockSize, usefulBytes - copied)
                                let src = bytes.baseAddress! + block * interleaveBlockSize + ch * blockSize
                                vDSP_vfltu8(src, 1, idx.baseAddress!, 1, vDSP_Length(n))
                                vDSP_vindex(popcountTable, idx.baseAddress!, 1,
                                            dst.baseAddress! + carried + copied, 1, vDSP_Length(n))
                                copied += n
                                block += 1
                            }
                        }
                    }

                    // Stage 2: FIR decimate everything a full filter window is available for
                    guard pending[ch].count >= firLen else { continue }
                    let outCount = (pending[ch].count - firLen) / stage2R + 1
                    var out = [Float](repeating: 0, count: outCount)
                    vDSP_desamp(pending[ch], vDSP_Stride(stage2R), firFilter, &out,
                                vDSP_Length(outCount), vDSP_Length(firLen))
                    pending[ch].removeFirst(outCount * stage2R)
                    pcm[ch] = out
                }
            }

            let frames = pcm.map(\.count).min() ?? 0
            guard frames > 0 else { continue }
            pcm.withUnsafeBufferPointers { pointers in
                meter.process(channels: pointers, frames: frames)
            }
            let take = min(frames, excerptFrames - excerpt[0].count)
            if take > 0 {
                for ch in 0..<channels { excerpt[ch].append(contentsOf: pcm[ch].prefix(take)) }
            }
        }

        guard !excerpt[0].isEmpty else {
            throw AudioReaderError.dsfParseError("Not enough data for decimation")
        }

        let (mono, left, right) = mixExcerpt(excerpt)

        return AudioData(
            samples: mono,
            leftChannel: left,
            rightChannel: right,
            sampleRate: pcmSampleRate,
            originalSampleRate: dsdSampleRate,
            channels: channelCount,
            bitDepth: bitsPerSample > 0 ? bitsPerSample : 1,
            codec: "DSD\(Int(dsdSampleRate / 44100)) (DSF)",
            duration: Double(sampleCount) / dsdSampleRate,
            dr14: meter.finish()
        )
    }
}

private extension Array where Element == [Float] {
    /// Stable base pointers for each inner array, valid for the duration of `body`.
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<Float>]) -> R) -> R {
        func recurse(_ index: Int, _ acc: [UnsafePointer<Float>]) -> R {
            guard index < count else { return body(acc) }
            return self[index].withUnsafeBufferPointer { recurse(index + 1, acc + [$0.baseAddress!]) }
        }
        return recurse(0, [])
    }
}
