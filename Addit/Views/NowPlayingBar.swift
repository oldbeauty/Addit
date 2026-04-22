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
                accentColor: themeService.accentColor,
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
                    Text(playerService.currentTrack?.displayName ?? "")
                        .font(.subheadline.bold())
                        .fadingTruncation()
                    if let error = playerService.playbackError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fadingTruncation()
                    } else {
                        Text(miniPlayerSubtitle)
                            .font(.caption)
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
                            .font(.title2)
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
    let accentColor: Color
    let waveformSamples: [Float]
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    private let barHeight: CGFloat = 20
    private let hitAreaHeight: CGFloat = 28
    private let minBarFraction: CGFloat = 0.08

    // Aesthetic targets. If the service hands us more samples than fit at this
    // spacing, we downsample (peak-per-bucket) so nothing ever clips off the
    // right edge.
    private let preferredGap: CGFloat = 3.5
    private let minBarWidth: CGFloat = 1.5
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

                // How many bars fit at the preferred spacing?
                let cellMin = minBarWidth + preferredGap
                let maxFit = max(1, Int((size.width + preferredGap) / cellMin))
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
                let gap: CGFloat = preferredGap
                let barWidth = max(minBarWidth, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                let progressX = size.width * progress

                for i in 0..<count {
                    let x = (barWidth + gap) * CGFloat(i)
                    let amplitude = CGFloat(max(Float(minBarFraction), samples[i]))
                    let h = amplitude * barHeight
                    let y = (barHeight - h) / 2 + (size.height - barHeight) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                    let isPast = x + barWidth <= progressX
                    let isPartial = x < progressX && x + barWidth > progressX

                    if isPast {
                        context.fill(path, with: .color(accentColor))
                    } else if isPartial {
                        // Split bar at the progress boundary
                        let splitX = progressX - x
                        let filledRect = CGRect(x: x, y: y, width: splitX, height: h)
                        let unfilledRect = CGRect(x: x + splitX, y: y, width: barWidth - splitX, height: h)
                        context.fill(Path(roundedRect: filledRect, cornerRadius: barWidth / 2),
                                     with: .color(accentColor))
                        context.fill(Path(roundedRect: unfilledRect, cornerRadius: barWidth / 2),
                                     with: .color(accentColor.opacity(0.25)))
                    } else {
                        context.fill(path, with: .color(accentColor.opacity(0.25)))
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
