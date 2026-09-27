# DrDoctor — Audio Mastering Analyzer

macOS SwiftUI app (Sonoma 14+). Analyzes DR, LUFS, clipping, spectral, stereo image. Reads DSF/DSD, FLAC, WAV, AIFF, MP3, AAC.

## Project Structure

```
DrDoctor/
  DrDoctorApp.swift          — App entry, AppDelegate (handles URLs from external apps)
  Info.plist                 — Document types for audio + DSF/DFF
  Audio/
    AudioFileReader.swift    — AVFoundation + custom DSF parser (CIC decimator)
    DynamicRangeAnalyzer.swift — DR score (3s blocks, top 20%, peak/RMS)
    SpectralAnalyzer.swift   — FFT spectral + fake lossless detection
    ClippingDetector.swift   — True peak, clipping detection
    StereoAnalyzer.swift     — L/R correlation, Mid/Side width, per-band, Lissajous
    MasteringVerdict.swift   — Score-based verdict (skips lossy detection for DSD)
  Models/
    AudioAnalysis.swift      — All result structs
    AudioFileInfo.swift      — File metadata
  Views/
    ContentView.swift        — Main view, all analysis flows, state management
    ComparisonView.swift     — A/B edition comparison
    FolderAnalysisView.swift — Album batch analysis table
    AnalysisResultView.swift — Single file analysis display
    WaveformView.swift       — Waveform visualization
    SpectrumView.swift       — Spectrum visualization (0 to -90dB fixed range)
    StereoImageView.swift    — Vectorscope + stereo metrics
    VerdictBadgeView.swift   — Verdict badge component
```

## Build, Sign & Deploy

### Code signing identity
- **Developer ID**: `Developer ID Application: carlos prieto ortiz (LFTD9T269J)`
- **Team ID**: `LFTD9T269J`

### Build & Archive
```bash
xcodebuild -project DrDoctor.xcodeproj -scheme DrDoctor -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: carlos prieto ortiz (LFTD9T269J)" \
  DEVELOPMENT_TEAM=LFTD9T269J CODE_SIGN_STYLE=Manual \
  archive -archivePath /tmp/DrDoctor.xcarchive
```

### Export (requires ExportOptions.plist)
```bash
# Create ExportOptions.plist if missing:
cat > /tmp/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>LFTD9T269J</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath /tmp/DrDoctor.xcarchive \
  -exportPath /tmp/DrDoctorExport -exportOptionsPlist /tmp/ExportOptions.plist
```

### Create DMG
```bash
VERSION="1.0.0"  # bump as needed
hdiutil create -volname "DrDoctor" -srcfolder /tmp/DrDoctorExport/DrDoctor.app \
  -ov -format UDZO "/tmp/DrDoctor-${VERSION}.dmg"
```

### Notarize
Credentials stored in keychain profile `"notarytool-profile"` (shared with the other Developer ID apps).
```bash
xcrun notarytool submit /tmp/DrDoctor-${VERSION}.dmg --keychain-profile "notarytool-profile" --wait
xcrun stapler staple /tmp/DrDoctor-${VERSION}.dmg
```

### Install locally
```bash
pkill -f DrDoctor 2>/dev/null; sleep 1
rm -rf /Applications/DrDoctor.app
cp -R /tmp/DrDoctorExport/DrDoctor.app /Applications/
```

### Full pipeline (build → export → DMG → notarize → install)
```bash
VERSION="1.0.0"
xcodebuild -project DrDoctor.xcodeproj -scheme DrDoctor -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: carlos prieto ortiz (LFTD9T269J)" \
  DEVELOPMENT_TEAM=LFTD9T269J CODE_SIGN_STYLE=Manual \
  archive -archivePath /tmp/DrDoctor.xcarchive && \
xcodebuild -exportArchive -archivePath /tmp/DrDoctor.xcarchive \
  -exportPath /tmp/DrDoctorExport -exportOptionsPlist /tmp/ExportOptions.plist && \
hdiutil create -volname "DrDoctor" -srcfolder /tmp/DrDoctorExport/DrDoctor.app \
  -ov -format UDZO "/tmp/DrDoctor-${VERSION}.dmg" && \
xcrun notarytool submit "/tmp/DrDoctor-${VERSION}.dmg" --keychain-profile "notarytool-profile" --wait && \
xcrun stapler staple "/tmp/DrDoctor-${VERSION}.dmg" && \
pkill -f DrDoctor 2>/dev/null; sleep 1 && \
rm -rf /Applications/DrDoctor.app && \
cp -R /tmp/DrDoctorExport/DrDoctor.app /Applications/
```

## Releases & Homebrew Cask

Repo is public (MIT). Each version is a GitHub Release (`v{VERSION}` tag) with the notarized DMG attached:
`https://github.com/prietus/drdoctor/releases/download/v{VERSION}/DrDoctor-{VERSION}.dmg`

Tap: `prietus/homebrew-drdoctor` at `/opt/homebrew/Library/Taps/prietus/homebrew-drdoctor`. The cask downloads from GitHub Releases and has `livecheck` (`github_latest`); only `version` and `sha256` change per release.

`scripts/release.sh VERSION` does the whole flow (modelled on drtagger for Mac's): build → sign → DMG → notarize + staple (keychain profile `notarytool-profile`) → install to /Applications → tag + GitHub release → cask bump. Artifacts land in `dist/`. Flags: `NOTARIZE=0`, `PUBLISH=0`, `INSTALL=0`. Publishing refuses a dirty tree, a non-main branch or an existing tag. Release notes come from `--generate-notes`.

### Update cask manually
```bash
VERSION="1.0.0"  # new version
SHA=$(shasum -a 256 "/tmp/DrDoctor-${VERSION}.dmg" | awk '{print $1}')
# Update version and sha256 in Casks/drdoctor.rb, then:
# brew style Casks/drdoctor.rb && brew audit --cask --online prietus/drdoctor/drdoctor
# cd /opt/homebrew/Library/Taps/prietus/homebrew-drdoctor && git commit -am "Update to v${VERSION}" && git push
```

## Landing Page

Hosted at `https://drdoctor.priet.us` via nginx. Older DMGs (up to 1.1.2) are also on the site at `https://drdoctor.priet.us/downloads/`; new releases are only published on GitHub.

## Known Gotchas

- **NSOpenPanel + DSF on SMB**: `OpenAndSavePanelService` hangs with unknown UTTypes on network shares. Don't set `allowedContentTypes` on NSOpenPanel. App provides path text field as fallback.
- **DSD files**: Skip lossy detection (CIC creates sharp 20kHz cutoff that triggers false positive). Check `codec.contains("DSD")`.
- **DSF sample rate**: Display `originalSampleRate` from AudioData, not the decimated PCM rate.
- **CIC overflow**: Use wrapping arithmetic (`&+=`, `&-=`) for Int64 integrators/combs.
- **DSF fmt chunk offsets** (relative to fmt chunk start): channelCount +24, sampleRate +28, bitsPerSample +32, sampleCount +36 (UInt64), blockSizePerChannel +44.
- **macOS caches old binary**: Always `pkill -f DrDoctor` before installing new version.
- **Task.detached**: Use `Task.detached(priority: .userInitiated)` for heavy processing — SwiftUI views inherit `@MainActor`.
- **Binary parsing**: Use `loadUnaligned(fromByteOffset:as:)` — Data doesn't guarantee alignment.
