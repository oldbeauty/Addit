import SwiftUI
import UIKit
import SwiftData

struct NowPlayingBar: View {
    @Binding var showFullPlayer: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @State private var seekValue: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var albumImage: UIImage?
    private let artworkSize: CGFloat = 44

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Draggable waveform scrubber
            MiniScrubber(
                value: isScrubbing ? seekValue : playerService.currentTime,
                duration: playerService.duration,
                waveformSamples: playerService.waveformSamples,
                onChanged: { newValue in
                    if !isScrubbing {
                        isScrubbing = true
                        playerService.beginSeeking()
                    }
                    seekValue = newValue
                    playerService.currentTime = newValue
                },
                onEnded: { finalValue in
                    playerService.endSeeking(to: finalValue)
                    isScrubbing = false
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeService.accentColor.opacity(0.2))
                    .frame(width: artworkSize, height: artworkSize)
                    .overlay {
                        Group {
                            if let albumImage {
                                Image(uiImage: albumImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: artworkSize, height: artworkSize)
                            } else {
                                Image(systemName: "music.note")
                                    .foregroundStyle(themeService.accentColor)
                                    .frame(width: artworkSize, height: artworkSize)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: playerService.currentTrack?.displayName ?? "")
                        .font(.uiSubheadline.bold())
                    if let error = playerService.playbackError {
                        Text(error)
                            .font(.uiCaption)
                            .foregroundStyle(.red)
                            .fadingTruncation()
                    } else {
                        Text(miniPlayerSubtitle)
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                            .fadingTruncation()
                    }
                }

                Spacer()

                if playerService.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Button {
                        playerService.togglePlayPause()
                    } label: {
                        Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.uiTitle2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onTapGesture {
            if !isScrubbing {
                showFullPlayer = true
            }
        }
        .task(id: artworkTaskID) {
            guard let album = playerService.currentTrack?.album else {
                albumImage = nil
                return
            }
            if album.isLocal {
                if let path = album.resolvedLocalCoverPath {
                    albumImage = UIImage(contentsOfFile: path)
                } else {
                    albumImage = nil
                }
            } else {
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                albumImage = resolution.image
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
        }
    }

    private var miniPlayerSubtitle: String {
        playerService.currentTrack?.album?.artistName ?? ""
    }
}

private struct MiniScrubber: View {
    let value: TimeInterval
    let duration: TimeInterval
    let waveformSamples: [Float]
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let barHeight: CGFloat = 20
    private let hitAreaHeight: CGFloat = 28
    private let minBarFraction: CGFloat = 0.08

    /// Pixel grid (Phosphor display layer): square cells matching
    /// MiniEQGrid's scale. 6 rows × 2.5pt cells + 1pt gaps = the 20pt bar.
    private let pixelRows = 6
    private let pixelGap: CGFloat = 1
    /// Horizontal half-width (points) of the grabbable area around the
    /// playhead. Touches outside this window fall through to the parent
    /// tap gesture (which opens the full player) instead of scrubbing.
    private let grabRadius: CGFloat = 22

    @State private var lastHapticBar: Int = -1
    @State private var hapticGenerator: UIImpactFeedbackGenerator?
    /// Tracks whether the in-flight drag began close enough to the
    /// playhead to count as a real scrub.
    @State private var isDragActive = false

    private var progress: Double {
        duration > 0 ? value / duration : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            Canvas { context, size in
                let rawSamples = waveformSamples.isEmpty
                    ? [Float](repeating: 0.15, count: 120)
                    : waveformSamples
                guard !rawSamples.isEmpty else { return }

                // Square pixel cells sized off the bar height, columns at the
                // same stride so the grid matches MiniEQGrid's scale.
                let rows = pixelRows
                let cell = (barHeight - CGFloat(rows - 1) * pixelGap) / CGFloat(rows)
                let colStride = cell + pixelGap
                let maxFit = max(1, Int((size.width + pixelGap) / colStride))
                let displayCount = min(rawSamples.count, maxFit)

                // Downsample to displayCount by taking the peak in each bucket
                // so the visual still reflects the loudest moment, not an
                // averaged-down mush.
                let samples: [Float]
                if displayCount == rawSamples.count {
                    samples = rawSamples
                } else {
                    var out = [Float](repeating: 0, count: displayCount)
                    for j in 0..<displayCount {
                        let start = j * rawSamples.count / displayCount
                        let end = (j + 1) * rawSamples.count / displayCount
                        var peak: Float = 0
                        for k in start..<end {
                            peak = max(peak, rawSamples[k])
                        }
                        out[j] = peak
                    }
                    samples = out
                }

                let count = samples.count
                let totalWidth = CGFloat(count) * colStride - pixelGap
                let x0 = (size.width - totalWidth) / 2
                let yTop = (size.height - barHeight) / 2

                // Quantized playhead: whole columns light up — the display
                // ticks cell by cell instead of gliding. (Phosphor motion
                // rule for the display layer.)
                let filledCols = Int((progress * Double(count)).rounded())

                // Lit-row count and vertical placement (center-mirrored
                // waveform silhouette) for one column.
                func litSpan(_ i: Int) -> (start: Int, count: Int) {
                    let amp = CGFloat(max(Float(minBarFraction), samples[i]))
                    let lit = max(1, min(rows, Int((amp * CGFloat(rows)).rounded())))
                    return ((rows - lit) / 2, lit)
                }

                // Phosphor bloom under the lit portion (dark mode only) —
                // one blurred layer, one rect per filled column.
                if colorScheme == .dark {
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 1.6))
                        for i in 0..<min(filledCols, count) {
                            let span = litSpan(i)
                            let rect = CGRect(
                                x: x0 + CGFloat(i) * colStride,
                                y: yTop + CGFloat(span.start) * colStride,
                                width: cell,
                                height: CGFloat(span.count) * colStride - pixelGap
                            ).insetBy(dx: -0.5, dy: -0.5)
                            layer.fill(Path(rect), with: .color(Phosphor.lit.opacity(0.45)))
                        }
                    }
                }

                // Crisp pixel pass.
                for i in 0..<count {
                    let span = litSpan(i)
                    let x = x0 + CGFloat(i) * colStride
                    let color = i < filledCols ? Phosphor.lit : Phosphor.ghost
                    for r in span.start..<(span.start + span.count) {
                        let rect = CGRect(x: x, y: yTop + CGFloat(r) * colStride, width: cell, height: cell)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: cell * 0.25),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(height: hitAreaHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // First event of the gesture — only engage if the
                        // touch started near the playhead. Otherwise stay
                        // inactive and ignore further events so the tap
                        // falls through to "open full player."
                        if !isDragActive {
                            let playheadX = width * progress
                            guard abs(drag.startLocation.x - playheadX) <= grabRadius else {
                                return
                            }
                            isDragActive = true
                        }

                        let fraction = max(0, min(1, drag.location.x / width))
                        onChanged(fraction * max(duration, 1))

                        // Haptic tick at fixed 40 discrete steps (independent of bar count)
                        let hapticSteps = 40
                        let currentBar = min(hapticSteps - 1, Int(fraction * CGFloat(hapticSteps)))
                        if currentBar != lastHapticBar {
                            if hapticGenerator == nil {
                                hapticGenerator = UIImpactFeedbackGenerator(style: .light)
                                hapticGenerator?.prepare()
                            }
                            hapticGenerator?.impactOccurred(intensity: 0.7)
                            lastHapticBar = currentBar
                        }
                    }
                    .onEnded { drag in
                        if isDragActive {
                            let fraction = max(0, min(1, drag.location.x / width))
                            onEnded(fraction * max(duration, 1))
                        }
                        isDragActive = false
                        lastHapticBar = -1
                        hapticGenerator = nil
                    }
            )
        }
        .frame(height: hitAreaHeight)
    }
}
