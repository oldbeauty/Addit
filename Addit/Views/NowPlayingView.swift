import SwiftUI
import UIKit
import SwiftData

struct NowPlayingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioAnalyzerService.self) private var analyzer
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue: TimeInterval = 0
    @State private var albumImage: UIImage?
    @State private var showQueueSheet = false
    @State private var showVisualizer = false

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            // Album / folder name — sits between the drag indicator and the cover
            Text(playerService.currentTrack?.album?.name ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 16)

            // Album art / EQ visualizer
            TabView(selection: $showVisualizer) {
                albumArtView
                    .tag(false)
                EQVisualizerView()
                    .padding(.top, 20)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .tag(true)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(radius: 20, y: 10)
            .padding(.horizontal, 40)
            .onChange(of: showVisualizer) { _, visible in
                if visible { analyzer.start() } else { analyzer.stop() }
            }

            // Page indicator icons
            HStack(spacing: 12) {
                // Album icon — small rounded square
                Image(systemName: "square.fill")
                    .font(.system(size: 8))
                    .foregroundColor(showVisualizer ? .secondary.opacity(0.4) : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                // EQ icon — small bar chart
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundColor(showVisualizer ? .primary : .secondary.opacity(0.4))
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            Spacer()
                .frame(height: 16)

            // Track info
            VStack(spacing: 4) {
                Text(playerService.currentTrack?.displayName ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                if let error = playerService.playbackError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text(nowPlayingSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Scrubber
            VStack(spacing: 4) {
                FullScrubber(
                    value: playerService.isSeeking ? seekValue : playerService.currentTime,
                    duration: playerService.duration,
                    accentColor: themeService.accentColor,
                    waveformSamples: playerService.waveformSamples,
                    onChanged: { newValue in
                        if !playerService.isSeeking {
                            seekValue = playerService.currentTime
                            playerService.beginSeeking()
                        }
                        seekValue = newValue
                        playerService.currentTime = newValue
                    },
                    onEnded: { finalValue in
                        playerService.endSeeking(to: finalValue)
                    }
                )

                HStack {
                    Text(formatTime(playerService.isSeeking ? seekValue : playerService.currentTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(playerService.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // Centered live waveform — shows ±1 s around the playhead,
            // scrolling right→left as playback progresses.
            CenteredWaveformView(
                currentTime: playerService.currentTime,
                duration: playerService.duration,
                accentColor: themeService.accentColor,
                samples: playerService.waveformSamples,
                samplesPerSecond: playerService.waveformSamplesPerSecond
            )
            .frame(width: 200, height: 36)

            Spacer(minLength: 16)

            // Playback controls
            HStack(spacing: 40) {
                Button {
                    playerService.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.caption.bold())
                        .foregroundStyle(playerService.isShuffleOn ? .white : .secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            if playerService.isShuffleOn {
                                Circle()
                                    .fill(themeService.accentColor)
                            }
                        }
                }

                Button {
                    playerService.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button {
                    playerService.togglePlayPause()
                } label: {
                    ZStack {
                        if playerService.isLoading {
                            ProgressView()
                                .scaleEffect(1.5)
                        } else {
                            Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 60))
                        }
                    }
                    .frame(width: 60, height: 60)
                }

                Button {
                    playerService.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }

                Button {
                    playerService.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatIcon)
                        .font(.caption.bold())
                        .foregroundStyle(playerService.repeatMode != .off ? .white : .secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            if playerService.repeatMode != .off {
                                Circle()
                                    .fill(themeService.accentColor)
                            }
                        }
                }
            }

            Spacer()

            // Queue button
            if !playerService.queue.isEmpty {
                Button {
                    showQueueSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(.primary.opacity(0.6))
                        .overlay(alignment: .topTrailing) {
                            if !playerService.userQueue.isEmpty {
                                Text("\(playerService.userQueue.count)")
                                    .font(.system(size: 10).bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(themeService.accentColor, in: Capsule())
                                    .offset(x: 10, y: -8)
                            }
                        }
                }
                .padding(.bottom, 16)
            }
        }
        .padding()
        .sheet(isPresented: $showQueueSheet) {
            QueueView()
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

    private var albumArtView: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(
                LinearGradient(
                    colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Group {
                    if let albumImage {
                        Image(uiImage: albumImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var nowPlayingSubtitle: String {
        playerService.currentTrack?.album?.artistName ?? ""
    }

    private var repeatIcon: String {
        switch playerService.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && !time.isNaN else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct FullScrubber: View {
    let value: TimeInterval
    let duration: TimeInterval
    let accentColor: Color
    let waveformSamples: [Float]
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    // Top + bottom waveform "ears" sit symmetrically around a center gap
    // containing the progress bar.
    private let earHeight: CGFloat = 26
    private let centerGap: CGFloat = 10         // vertical space between top+bottom ears
    private let trackHeight: CGFloat = 4        // thickness of the progress capsule
    private let minBarFraction: CGFloat = 0.08
    private let preferredGap: CGFloat = 3.5
    private let minBarWidth: CGFloat = 1.5
    private let hapticSteps: Int = 40

    @State private var lastHapticStep: Int = -1
    @State private var hapticGenerator: UIImpactFeedbackGenerator?

    private var progress: Double {
        duration > 0 ? value / duration : 0
    }

    private var totalHeight: CGFloat {
        earHeight * 2 + centerGap
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack {
                // Stereo-style waveform — bars mirror around a central gap.
                Canvas { context, size in
                    let rawSamples = waveformSamples.isEmpty
                        ? [Float](repeating: 0.15, count: 120)
                        : waveformSamples
                    guard !rawSamples.isEmpty else { return }

                    // Downsample (peak-per-bucket) to whatever fits at the
                    // preferred spacing so nothing clips.
                    let cellMin = minBarWidth + preferredGap
                    let maxFit = max(1, Int((size.width + preferredGap) / cellMin))
                    let displayCount = min(rawSamples.count, maxFit)

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

                    let topEarBottom = earHeight                            // bottom edge of the upper ear
                    let bottomEarTop = earHeight + centerGap                // top edge of the lower ear

                    for i in 0..<count {
                        let x = (barWidth + gap) * CGFloat(i)
                        let amplitude = CGFloat(max(Float(minBarFraction), samples[i]))
                        let h = amplitude * earHeight

                        // Upper ear — bar grows UP from the inner edge (topEarBottom)
                        let topRect = CGRect(x: x, y: topEarBottom - h, width: barWidth, height: h)
                        // Lower ear — bar grows DOWN from the inner edge (bottomEarTop)
                        let botRect = CGRect(x: x, y: bottomEarTop, width: barWidth, height: h)

                        let isPast = x + barWidth <= progressX
                        let isPartial = x < progressX && x + barWidth > progressX

                        let filled = accentColor
                        let unfilled = accentColor.opacity(0.25)

                        func drawBar(_ rect: CGRect) {
                            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                            if isPast {
                                context.fill(path, with: .color(filled))
                            } else if isPartial {
                                let splitX = progressX - x
                                let filledRect = CGRect(x: rect.minX, y: rect.minY, width: splitX, height: rect.height)
                                let unfilledRect = CGRect(x: rect.minX + splitX, y: rect.minY, width: rect.width - splitX, height: rect.height)
                                context.fill(Path(roundedRect: filledRect, cornerRadius: barWidth / 2),
                                             with: .color(filled))
                                context.fill(Path(roundedRect: unfilledRect, cornerRadius: barWidth / 2),
                                             with: .color(unfilled))
                            } else {
                                context.fill(path, with: .color(unfilled))
                            }
                        }

                        drawBar(topRect)
                        drawBar(botRect)
                    }
                }

                // Thin progress capsule sitting in the central gap — no thumb.
                VStack(spacing: 0) {
                    Spacer().frame(height: earHeight + (centerGap - trackHeight) / 2)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(accentColor.opacity(0.2))
                            .frame(height: trackHeight)
                        Capsule()
                            .fill(accentColor)
                            .frame(width: max(0, width * progress), height: trackHeight)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .frame(height: totalHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = max(0, min(1, drag.location.x / width))
                        onChanged(fraction * max(duration, 1))

                        let currentStep = min(hapticSteps - 1, Int(fraction * CGFloat(hapticSteps)))
                        if currentStep != lastHapticStep {
                            if hapticGenerator == nil {
                                hapticGenerator = UIImpactFeedbackGenerator(style: .light)
                                hapticGenerator?.prepare()
                            }
                            hapticGenerator?.impactOccurred(intensity: 0.7)
                            lastHapticStep = currentStep
                        }
                    }
                    .onEnded { drag in
                        let fraction = max(0, min(1, drag.location.x / width))
                        onEnded(fraction * max(duration, 1))
                        lastHapticStep = -1
                        hapticGenerator = nil
                    }
            )
        }
        .frame(height: totalHeight)
    }
}

/// Narrow "radar" waveform — shows a fixed 2-second window centered on the
/// current playback position.  Bars scroll right→left as playback advances.
/// Edges fade out (unseen future fading in on the right, past fading out on
/// the left).
private struct CenteredWaveformView: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let accentColor: Color
    /// Waveform samples (0…1) for the whole track.
    let samples: [Float]
    /// How many samples correspond to one second of audio.
    let samplesPerSecond: Double

    /// Half-width of the visible window, in seconds.  Full window = 2 × this.
    private let halfWindow: TimeInterval = 2.0
    private let preferredGap: CGFloat = 3.0
    private let minBarWidth: CGFloat = 1.5
    private let minBarFraction: CGFloat = 0.12

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !samples.isEmpty, samplesPerSecond > 0 else { return }

                let startTime = currentTime - halfWindow
                let endTime = currentTime + halfWindow
                let windowSeconds = endTime - startTime    // = 2 × halfWindow

                // How many bars fit at preferred spacing?
                let cellMin = minBarWidth + preferredGap
                let maxFit = max(4, Int((size.width + preferredGap) / cellMin))

                let count = maxFit
                let gap = preferredGap
                let barWidth = max(minBarWidth, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))

                // Vertical centerline — bars grow from the center outward.
                let centerY = size.height / 2
                let maxHalfHeight = size.height / 2

                // Time range each bar covers — peak-per-bucket prevents the
                // "popping" aliasing you get when a bar spans multiple
                // underlying samples but picks only one of them.
                let barDuration = windowSeconds / Double(count)

                for i in 0..<count {
                    // Map bar index → time offset within the visible window
                    let fraction = (CGFloat(i) + 0.5) / CGFloat(count)
                    let t = startTime + Double(fraction) * windowSeconds

                    // Fade each bar based on distance from the playhead so the
                    // edges visually breathe.  fade = 1 at center, 0 at edges.
                    let distFromCenter = abs(Double(fraction) - 0.5) * 2.0  // 0…1
                    let fade = max(0, 1.0 - pow(distFromCenter, 1.6))

                    // Peak amplitude across this bar's time slice.
                    let tStart = t - barDuration / 2
                    let tEnd = t + barDuration / 2
                    var amp: Float = 0
                    if tEnd > 0, tStart < duration {
                        let idxStart = max(0, Int(tStart * samplesPerSecond))
                        let idxEnd = min(samples.count, Int(ceil(tEnd * samplesPerSecond)))
                        if idxEnd > idxStart {
                            for k in idxStart..<idxEnd {
                                amp = max(amp, samples[k])
                            }
                        }
                    }

                    let normalised = max(Float(minBarFraction), amp)
                    let halfH = CGFloat(normalised) * maxHalfHeight
                    let x = (barWidth + gap) * CGFloat(i)

                    let rect = CGRect(x: x, y: centerY - halfH, width: barWidth, height: halfH * 2)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(accentColor.opacity(fade)))
                }
            }
            // Feather the edges so new bars fade IN on the right and fade
            // OUT on the left as they scroll past — masks the hard-edge
            // clipping that otherwise happens when a bar enters the window.
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}
