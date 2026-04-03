import SwiftUI
import UniformTypeIdentifiers
import Accelerate

struct ContentView: View {
    var appState: AppState
    @State private var analysis: AudioAnalysis?
    @State private var folderTracks: [TrackSummary]?
    @State private var albumSummary: AlbumSummary?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isDragOver = false
    @State private var progress: Double = 0
    @State private var progressMessage = ""
    @State private var pathText = ""

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if let analysis = analysis {
                AnalysisResultView(analysis: analysis, onNewFile: reset)
            } else if let tracks = folderTracks, let summary = albumSummary {
                FolderAnalysisView(
                    tracks: tracks,
                    albumSummary: summary,
                    onSelectTrack: { selected in analysis = selected },
                    onBack: reset
                )
            } else if isAnalyzing {
                analysingView
            } else {
                dropZoneView
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .onChange(of: appState.pendingFileURL) {
            if let url = appState.pendingFileURL {
                appState.pendingFileURL = nil
                handleOpenURL(url)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: isDragOver)

            Text("Dr. Doctor")
                .font(.largeTitle.bold())

            Text("Audio Mastering Analyzer")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Drop an audio file here or click to browse")
                    .font(.body)
                    .foregroundStyle(isDragOver ? .primary : .tertiary)

                Text("WAV  FLAC  AIFF  ALAC  DSF  DFF  MP3  AAC  M4A")
                    .font(.caption.monospaced())
                    .foregroundStyle(.quaternary)
            }

            HStack(spacing: 16) {
                Button {
                    openFilePicker()
                } label: {
                    Label("Choose File", systemImage: "doc.badge.gearshape")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    openFolderPicker()
                } label: {
                    Label("Analyze Folder", systemImage: "folder.badge.gearshape")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Divider().frame(width: 200).padding(.vertical, 4)

            // Path input as fallback for network drives where the file picker may be slow
            VStack(spacing: 10) {
                Text("Or paste the file path (useful for network drives):")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    TextField("/Volumes/Music/track.dsf", text: $pathText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { submitPath() }

                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            pathText = clip
                            submitPath()
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("Paste from clipboard and analyze")

                    Button("Analyze") { submitPath() }
                        .buttonStyle(.borderedProminent)
                        .disabled(pathText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(maxWidth: 600)

                Text("Tip: In Finder, right-click → Copy as Pathname (⌥⌘C)")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDragOver ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: [10])
                )
                .padding(20)
        }
    }

    // MARK: - Analysing View

    private var analysingView: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress, total: 1.0) {
                Text("Analyzing...")
                    .font(.headline)
            }
            .progressViewStyle(.linear)
            .frame(width: 300)

            Text(progressMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private static let supportedExtensions: Set<String> = [
        "wav", "flac", "aif", "aiff", "alac", "m4a", "mp3", "aac", "ogg", "dsf", "dff"
    ]

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let ext = url.pathExtension.lowercased()
                if Self.supportedExtensions.contains(ext) {
                    self.analyzeFile(url: url)
                } else {
                    self.errorMessage = "Unsupported format: .\(ext)"
                    self.showError = true
                }
            }
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select a folder with audio files to analyze"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.analyzeFolder(url: url)
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            errorMessage = "Unsupported format: .\(ext)"
            showError = true
            return
        }
        // Reset any previous analysis and start new one
        analysis = nil
        analyzeFile(url: url)
    }

    private func submitPath() {
        let cleaned = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\ ", with: " ")
        guard !cleaned.isEmpty else { return }

        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension.lowercased()

        guard Self.supportedExtensions.contains(ext) else {
            errorMessage = ext.isEmpty ? "Please enter a file path" : "Unsupported format: .\(ext)"
            showError = true
            return
        }

        // Don't call fileExists - it blocks on network paths. Let the reader fail with a clear error.
        analyzeFile(url: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    analyzeFile(url: url)
                }
            }
            return true
        }
        return false
    }

    private func analyzeFile(url: URL) {
        isAnalyzing = true
        errorMessage = nil
        progress = 0
        progressMessage = "Reading audio file..."

        Task.detached(priority: .userInitiated) {
            do {
                // Step 1: Read the file
                let audioData = try await AudioFileReader.read(url: url)
                await MainActor.run { progress = 0.2; progressMessage = "Analyzing dynamic range..." }

                // Step 2: Dynamic range analysis
                let drResult = DynamicRangeAnalyzer.analyze(
                    samples: audioData.samples,
                    sampleRate: audioData.sampleRate
                )
                await MainActor.run { progress = 0.4; progressMessage = "Performing spectral analysis..." }

                // Step 3: Spectral analysis
                let spectralResult = SpectralAnalyzer.analyze(
                    samples: audioData.samples,
                    sampleRate: audioData.sampleRate
                )
                await MainActor.run { progress = 0.6; progressMessage = "Detecting clipping..." }

                // Step 4: Clipping detection
                let clippingResult = ClippingDetector.analyze(
                    samples: audioData.samples,
                    sampleRate: audioData.sampleRate
                )
                await MainActor.run { progress = 0.7; progressMessage = "Analyzing stereo image..." }

                // Step 4b: Stereo image analysis
                let stereoResult: StereoImageResult?
                if let left = audioData.leftChannel, let right = audioData.rightChannel {
                    stereoResult = StereoAnalyzer.analyze(left: left, right: right, sampleRate: audioData.sampleRate)
                } else {
                    stereoResult = nil
                }
                await MainActor.run { progress = 0.85; progressMessage = "Computing verdict..." }

                // Step 5: Generate waveform data
                let waveform = Self.generateWaveformData(samples: audioData.samples)

                // Step 6: Generate spectrum display data
                // Don't show cutoff marker for DSD (our FIR filter creates a natural cutoff)
                let isDSD = audioData.codec.uppercased().contains("DSD")
                let spectrumDisplay = SpectrumData(
                    magnitudes: spectralResult.averageSpectrum,
                    frequencies: spectralResult.frequencyBins,
                    cutoffMarker: isDSD ? nil : spectralResult.detectedCutoffHz.map { Float($0) }
                )

                // Step 7: Verdict
                let verdict = MasteringVerdictEngine.evaluate(
                    dynamicRange: drResult,
                    spectral: spectralResult,
                    clipping: clippingResult,
                    codec: audioData.codec
                )

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let fileInfo = AudioFileInfo(
                    url: url,
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.uppercased(),
                    fileSize: fileSize,
                    sampleRate: audioData.sampleRate,
                    bitDepth: audioData.bitDepth,
                    channels: audioData.channels,
                    duration: audioData.duration,
                    codec: audioData.codec
                )

                let result = AudioAnalysis(
                    fileInfo: fileInfo,
                    dynamicRange: drResult,
                    spectral: spectralResult,
                    clipping: clippingResult,
                    stereoImage: stereoResult,
                    verdict: verdict,
                    waveformData: waveform,
                    spectrumData: spectrumDisplay
                )

                await MainActor.run {
                    progress = 1.0
                    analysis = result
                    isAnalyzing = false
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzing = false
                }
            }
        }
    }

    private nonisolated static func generateWaveformData(samples: [Float]) -> WaveformData {
        let targetPoints = 2000
        let samplesPerPoint = max(1, samples.count / targetPoints)
        let pointCount = samples.count / samplesPerPoint

        var minSamples = [Float](repeating: 0, count: pointCount)
        var maxSamples = [Float](repeating: 0, count: pointCount)
        var rmsEnvelope = [Float](repeating: 0, count: pointCount)

        for i in 0..<pointCount {
            let start = i * samplesPerPoint
            let end = min(start + samplesPerPoint, samples.count)
            let slice = Array(samples[start..<end])

            var minVal: Float = 0
            var maxVal: Float = 0
            vDSP_minv(slice, 1, &minVal, vDSP_Length(slice.count))
            vDSP_maxv(slice, 1, &maxVal, vDSP_Length(slice.count))

            var rms: Float = 0
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(slice.count))

            minSamples[i] = minVal
            maxSamples[i] = maxVal
            rmsEnvelope[i] = rms
        }

        return WaveformData(minSamples: minSamples, maxSamples: maxSamples, rmsEnvelope: rmsEnvelope)
    }

    // MARK: - Folder Analysis

    private func analyzeFolder(url: URL) {
        isAnalyzing = true
        errorMessage = nil
        progress = 0
        progressMessage = "Scanning folder..."

        Task.detached(priority: .userInitiated) {
            do {
                // Find audio files in folder
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                let audioFiles = contents
                    .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

                guard !audioFiles.isEmpty else {
                    await MainActor.run {
                        errorMessage = "No audio files found in this folder."
                        showError = true
                        isAnalyzing = false
                    }
                    return
                }

                var tracks = [TrackSummary]()

                for (index, fileURL) in audioFiles.enumerated() {
                    let trackNum = index + 1
                    await MainActor.run {
                        progress = Double(index) / Double(audioFiles.count)
                        progressMessage = "Analyzing \(trackNum)/\(audioFiles.count): \(fileURL.lastPathComponent)"
                    }

                    // Analyze each track (reuse single-file pipeline)
                    let audioData = try await AudioFileReader.read(url: fileURL)

                    let drResult = DynamicRangeAnalyzer.analyze(samples: audioData.samples, sampleRate: audioData.sampleRate)
                    let spectralResult = SpectralAnalyzer.analyze(samples: audioData.samples, sampleRate: audioData.sampleRate)
                    let clippingResult = ClippingDetector.analyze(samples: audioData.samples, sampleRate: audioData.sampleRate)

                    let stereoResult: StereoImageResult?
                    if let left = audioData.leftChannel, let right = audioData.rightChannel {
                        stereoResult = StereoAnalyzer.analyze(left: left, right: right, sampleRate: audioData.sampleRate)
                    } else {
                        stereoResult = nil
                    }

                    let waveform = Self.generateWaveformData(samples: audioData.samples)
                    let isDSD = audioData.codec.uppercased().contains("DSD")
                    let spectrumDisplay = SpectrumData(
                        magnitudes: spectralResult.averageSpectrum,
                        frequencies: spectralResult.frequencyBins,
                        cutoffMarker: isDSD ? nil : spectralResult.detectedCutoffHz.map { Float($0) }
                    )
                    let verdict = MasteringVerdictEngine.evaluate(
                        dynamicRange: drResult, spectral: spectralResult,
                        clipping: clippingResult, codec: audioData.codec
                    )

                    let fileSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                    let fileInfo = AudioFileInfo(
                        url: fileURL, fileName: fileURL.lastPathComponent,
                        fileExtension: fileURL.pathExtension.uppercased(), fileSize: fileSize,
                        sampleRate: audioData.sampleRate, bitDepth: audioData.bitDepth,
                        channels: audioData.channels, duration: audioData.duration, codec: audioData.codec
                    )

                    let trackAnalysis = AudioAnalysis(
                        fileInfo: fileInfo, dynamicRange: drResult, spectral: spectralResult,
                        clipping: clippingResult, stereoImage: stereoResult,
                        verdict: verdict, waveformData: waveform, spectrumData: spectrumDisplay
                    )

                    tracks.append(TrackSummary(
                        trackNumber: trackNum, fileName: fileURL.deletingPathExtension().lastPathComponent,
                        url: fileURL, analysis: trackAnalysis
                    ))
                }

                // Compute album summary
                let avgDR = tracks.map(\.analysis.dynamicRange.drScore).reduce(0, +) / Double(tracks.count)
                let avgLUFS = tracks.map(\.analysis.dynamicRange.integratedLUFS).reduce(0, +) / Double(tracks.count)
                let maxPeak = tracks.map(\.analysis.clipping.truePeakDB).max() ?? -100
                let worstClip = tracks.map(\.analysis.clipping.clippingPercentage).max() ?? 0

                let overallVerdict: MasteringVerdict
                if avgDR >= 12 && avgLUFS < -10 { overallVerdict = .excellent }
                else if avgDR >= 8 { overallVerdict = .good }
                else if avgDR >= 5 { overallVerdict = .mediocre }
                else { overallVerdict = .poor }

                let summary = AlbumSummary(
                    folderName: url.lastPathComponent, trackCount: tracks.count,
                    avgDR: avgDR, avgLUFS: avgLUFS, maxTruePeak: maxPeak,
                    worstClipping: worstClip, overallVerdict: overallVerdict
                )

                await MainActor.run {
                    progress = 1.0
                    folderTracks = tracks
                    albumSummary = summary
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzing = false
                }
            }
        }
    }

    private func reset() {
        analysis = nil
        folderTracks = nil
        albumSummary = nil
        isAnalyzing = false
        progress = 0
    }
}
