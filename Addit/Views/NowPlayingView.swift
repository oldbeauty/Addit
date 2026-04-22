import SwiftUI
import UIKit
import SwiftData

struct NowPlayingView: View {
    /// Called when the user taps the album artwork tile. The host is
    /// expected to push the album onto its navigation stack and dismiss
    /// this sheet, so the album view appears behind the dismissing player.
    var onOpenAlbum: ((Album) -> Void)? = nil

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
                .fadingTruncation(alignment: .center)
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
                    .fadingTruncation(alignment: .center)
                if let error = playerService.playbackError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fadingTruncation(alignment: .center)
                } else {
                    Text(nowPlayingSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fadingTruncation(alignment: .center)
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

            // Centered live waveform — shows ±2 s around the playhead,
            // scrolling right→left as playback progresses. Also acts as
            // a high-precision scrubber: dragging maps ~20 ms per point,
            // versus the full-width scrubber above where one point covers
            // a much larger slice of the track.
            CenteredWaveformView(
                currentTime: playerService.isSeeking ? seekValue : playerService.currentTime,
                duration: playerService.duration,
                accentColor: themeService.accentColor,
                samples: playerService.waveformSamples,
                samplesPerSecond: playerService.waveformSamplesPerSecond,
                onScrubStart: {
                    if !playerService.isSeeking {
                        seekValue = playerService.currentTime
                        playerService.beginSeeking()
                    }
                },
                onScrubChange: { newValue in
                    seekValue = newValue
                    playerService.currentTime = newValue
                },
                onScrubEnd: { finalValue in
                    playerService.endSeeking(to: finalValue)
                }
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
            // Tap-to-open-album lives on the artwork tile itself, not the
            // enclosing TabView, so the horizontal page swipe that flips
            // to the EQ visualizer keeps working unchanged.
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture {
                guard let album = playerService.currentTrack?.album else { return }
                onOpenAlbum?(album)
            }
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
    /// Horizontal half-width (in points) of the grabbable area around the
    /// playhead. Touches that start outside this window are ignored so the
    /// scrubber behaves like a traditional slider "thumb" — you must grab
    /// the current playback position to scrub, not tap-to-seek.
    private let grabRadius: CGFloat = 22

    @State private var lastHapticStep: Int = -1
    @State private var hapticGenerator: UIImpactFeedbackGenerator?
    /// Tracks whether the in-flight drag was accepted (started near the
    /// playhead). Prevents spurious onChanged/onEnded callbacks for touches
    /// that began outside the grab window.
    @State private var isDragActive = false

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
                        // On the first event of the gesture, decide
                        // whether the touch began close enough to the
                        // playhead to count as a scrub. If not, we stay
                        // inactive and swallow further events too.
                        if !isDragActive {
                            let playheadX = width * progress
                            guard abs(drag.startLocation.x - playheadX) <= grabRadius else {
                                return
                            }
                            isDragActive = true
                        }

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
                        // Only finalize a seek if the gesture was actually
                        // engaged from within the grab window.
                        if isDragActive {
                            let fraction = max(0, min(1, drag.location.x / width))
                            onEnded(fraction * max(duration, 1))
                        }
                        isDragActive = false
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
    /// Called once when a precision scrub begins. Hosts typically stash the
    /// current playhead and invoke `AudioPlayerService.beginSeeking()` here.
    var onScrubStart: (() -> Void)? = nil
    /// Called on every drag update with the new target time (already
    /// clamped to `0…duration`). Hosts should mirror this into
    /// `playerService.currentTime` so the waveform re-centers live.
    var onScrubChange: ((TimeInterval) -> Void)? = nil
    /// Called when the drag ends with the final target time. Hosts should
    /// invoke `AudioPlayerService.endSeeking(to:)` here.
    var onScrubEnd: ((TimeInterval) -> Void)? = nil

    /// Used to snap bar positions to whole device pixels so Canvas edges
    /// stay crisp instead of anti-aliasing across fractional offsets.
    @Environment(\.displayScale) private var displayScale

    /// Playhead time captured when the drag began. Finger translation is
    /// applied relative to this baseline, not the continuously-updating
    /// `currentTime` — otherwise the baseline would drift during the drag
    /// (since we feed seeks back into `currentTime`) and the gesture would
    /// become non-linear.
    @State private var dragStartTime: TimeInterval?

    /// Half-width of the visible window, in seconds.  Full window = 2 × this.
    private let halfWindow: TimeInterval = 2.0
    /// Match FullScrubber's geometry exactly so bars above and below look
    /// like parts of the same waveform family.
    private let barWidth: CGFloat = 1.5
    private let barGap: CGFloat = 3.5
    private let minBarFraction: CGFloat = 0.12
    /// Thin horizontal marks at the top and bottom of the view that a
    /// clipping song's bars will just barely touch.  Thickness matches
    /// barWidth; span is roughly the width of a letter.
    private let clipLineThickness: CGFloat = 1.5
    private let clipLineLength: CGFloat = 12

    /// Fully-opaque equivalent of the SwiftUI `.secondary` color.  The
    /// default `Color.secondary` bakes in ~40% transparency so opaque
    /// waveform bars show through any marker drawn in front of them,
    /// making the marker *look* like it's behind the waveform.  Resolving
    /// the system's secondary label color and forcing alpha to 1.0 keeps
    /// dark/light-mode adaptation while blocking the bars cleanly.
    private var opaqueSecondary: Color {
        Color(uiColor: UIColor { trait in
            UIColor.secondaryLabel.resolvedColor(with: trait).withAlphaComponent(1.0)
        })
    }

    /// Center-to-center screen distance between consecutive bars (matches
    /// FullScrubber's cell spacing: barWidth + gap).
    private var cellSpacing: CGFloat { barWidth + barGap }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !samples.isEmpty, samplesPerSecond > 0 else { return }

                let windowSeconds = halfWindow * 2
                let startTime = currentTime - halfWindow
                let endTime = currentTime + halfWindow

                // Vertical centerline — bars grow from the center outward.
                // Max half-height leaves room for the clip-indicator lines
                // at the top and bottom, so a fully-clipped bar's edge just
                // meets the inner edge of the indicator line.
                let centerY = size.height / 2
                let maxHalfHeight = size.height / 2 - clipLineThickness

                // Pick barTimeStep so screen spacing matches FullScrubber's
                // cell width (barWidth + gap).  Computed from actual size so
                // the match holds regardless of how wide this view is rendered.
                let barTimeStep = Double(cellSpacing) * windowSeconds / Double(size.width)
                guard barTimeStep > 0 else { return }

                // Iterate bar indices whose fixed audio time falls inside the
                // visible window.  Each bar's time is barIdx × barTimeStep —
                // constant for the entire song.  As currentTime advances,
                // the range of barIdx shifts and each bar's x position
                // decreases, producing continuous right-to-left motion.
                let firstBarIdx = Int(ceil(startTime / barTimeStep))
                let lastBarIdx = Int(floor(endTime / barTimeStep))
                guard firstBarIdx <= lastBarIdx else { return }

                for barIdx in firstBarIdx...lastBarIdx {
                    let barTime = Double(barIdx) * barTimeStep
                    if barTime < 0 || barTime > duration { continue }

                    // Peak amplitude across this bar's time slice.  Stable
                    // because the slice boundaries are fixed in audio time.
                    let tStart = barTime - barTimeStep / 2
                    let tEnd = barTime + barTimeStep / 2
                    var amp: Float = 0
                    let idxStart = max(0, Int(tStart * samplesPerSecond))
                    let idxEnd = min(samples.count, Int(ceil(tEnd * samplesPerSecond)))
                    if idxEnd > idxStart {
                        for k in idxStart..<idxEnd {
                            amp = max(amp, samples[k])
                        }
                    }

                    // x position — barTime==currentTime lands on center.
                    let xFrac = (barTime - startTime) / windowSeconds
                    let xCenter = CGFloat(xFrac) * size.width
                    // Snap the bar's left edge to the nearest device pixel so
                    // Canvas draws on clean pixel boundaries.  Without this,
                    // fractional-point offsets (inevitable when position is
                    // derived from a continuously-advancing currentTime)
                    // get anti-aliased across two device pixels and the whole
                    // bar looks soft.
                    let scale = max(displayScale, 1)
                    let rawX = xCenter - barWidth / 2
                    let x = (rawX * scale).rounded() / scale

                    // Fade by distance from playhead so edges breathe in+out,
                    // but keep a "hot zone" around the center at full opacity
                    // so center bars match the crispness/brightness of the
                    // full-width waveform above.
                    let distFromCenter = abs(xFrac - 0.5) * 2.0  // 0…1
                    let holdRadius: Double = 0.35               // inner 35% stays solid
                    let t = max(0, (distFromCenter - holdRadius) / (1 - holdRadius))
                    let fade = max(0, 1.0 - pow(t, 1.6))

                    let normalised = max(Float(minBarFraction), amp)
                    let halfH = CGFloat(normalised) * maxHalfHeight

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
            // Clipping indicator lines — drawn outside the mask so they
            // stay fully visible regardless of horizontal position.
            .overlay(alignment: .top) {
                Capsule()
                    .fill(opaqueSecondary)
                    .frame(width: clipLineLength, height: clipLineThickness)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(opaqueSecondary)
                    .frame(width: clipLineLength, height: clipLineThickness)
            }
            // Short vertical play-marker lines — hang down from the top
            // clip line and up from the bottom one, marking the exact
            // center (playhead) of the waveform window.
            .overlay(alignment: .top) {
                Capsule()
                    .fill(opaqueSecondary)
                    .frame(width: clipLineThickness, height: clipLineLength / 2)
                    .offset(y: clipLineThickness)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(opaqueSecondary)
                    .frame(width: clipLineThickness, height: clipLineLength / 2)
                    .offset(y: -clipLineThickness)
            }
            // Precision scrub — finger translation maps to seconds via the
            // view's visible window span, giving ~windowSeconds/width
            // seconds per point (≈20 ms/pt for a 4 s window across 200 pt).
            // Drag right → rewind (reveals past to the left); drag left →
            // fast-forward (reveals future from the right) — consistent
            // with iOS scroll direction conventions.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let windowSeconds = halfWindow * 2
                        if dragStartTime == nil {
                            dragStartTime = currentTime
                            onScrubStart?()
                        }
                        guard let baseline = dragStartTime,
                              geo.size.width > 0 else { return }
                        let secondsPerPoint = windowSeconds / Double(geo.size.width)
                        let delta = -Double(drag.translation.width) * secondsPerPoint
                        let target = max(0, min(duration, baseline + delta))
                        onScrubChange?(target)
                    }
                    .onEnded { drag in
                        let windowSeconds = halfWindow * 2
                        if let baseline = dragStartTime, geo.size.width > 0 {
                            let secondsPerPoint = windowSeconds / Double(geo.size.width)
                            let delta = -Double(drag.translation.width) * secondsPerPoint
                            let target = max(0, min(duration, baseline + delta))
                            onScrubEnd?(target)
                        }
                        dragStartTime = nil
                    }
            )
        }
    }
}
