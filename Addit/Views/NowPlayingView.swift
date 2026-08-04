import SwiftUI
import UIKit
import SwiftData

/// The expanded state of `NowPlayingPill` — content only. It is *not* a sheet
/// and doesn't own a background, a width, or its own dismissal.
///
/// This view is **always present**, at both ends of the morph and everywhere
/// between: the pill lays it out at its full height permanently and clips it,
/// and `progress` decides what you can see of it. That means:
///
/// - Nothing here may size itself from the available height, and nothing may
///   be added that only makes sense expanded — the collapsed pill is this same
///   view, faded down to its four travelling components.
/// - Those four components (artwork, track info, scrubber, play/pause) live in
///   `MorphSlot`s, which draw them somewhere between the position the layout
///   below gives them and the position `MiniLayout` defines for the mini bar.
///   Everything else is `.nowPlayingChrome(progress)` and simply fades.
/// - The card is narrower than the old sheet (the pill's 12pt insets, then
///   this view's own), so horizontal budgets are tight — the transport row in
///   particular is spaced to fit rather than to breathe.
struct NowPlayingView: View {
    /// 0 = collapsed to the mini bar, 1 = fully expanded. Drives every
    /// transform in this file; nothing here animates by resizing.
    let progress: CGFloat

    /// The card's current size, which is what `MiniLayout`'s frames are
    /// measured against. Its height changes as the pill opens; its width
    /// never does.
    let cardSize: CGSize

    /// Raised for the length of a scrub on either scrubber. It belongs to the
    /// pill, whose tap-to-expand gesture is the thing that has to ignore the
    /// touch-up that ends a scrub.
    @Binding var isScrubbing: Bool

    /// Called when the user taps the album artwork while expanded. The host
    /// pushes the album and collapses the pill, so the album view is what's
    /// behind the shrinking card.
    var onOpenAlbum: ((Album) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.colorScheme) private var colorScheme
    @State private var seekValue: TimeInterval = 0
    @State private var albumImage: UIImage?
    /// The current cover's own colour, or `nil` for art with none to take.
    @State private var coverAccent: Color?

    /// `coverAccent` already pushed to a luminance that reads in the current
    /// scheme — the finished value the waveform draws with.
    ///
    /// Both of these are cached rather than derived in `body`, and for the same
    /// reason: this body reads `currentTime`, so it re-runs on every playhead
    /// tick. Deriving the colour there would repeat a pixel scan *and* a
    /// `UIColor` round-trip dozens of times a second to reach the same answer.
    /// The two inputs that can change it — the artwork and the colour scheme —
    /// each recompute it once, in `refreshCoverAccent`.
    @State private var legibleCoverAccent: Color?
    @State private var showQueueSheet = false
    @State private var showVisualizer = false
    /// Live drag offset for the custom two-page pager that flips between
    /// the album cover and the EQ visualizer. Combined with `showVisualizer`
    /// this yields a continuous 0…1 progress used to morph the cover into
    /// the ambient halo mid-swipe.
    @State private var dragOffset: CGFloat = 0
    /// The halfway point of the morph, and so which set of controls is the
    /// live one. `MorphSlot` hands hit-testing over at the same threshold.
    private var isCollapsed: Bool { progress < 0.5 }

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            artwork

            pageIndicator

            Spacer()
                .frame(height: 16)

            trackInfo

            Spacer()
                .frame(height: 24)

            scrubber

            Spacer(minLength: 16)

            centeredWaveform

            Spacer(minLength: 16)

            transportControls

            Spacer()

            queueButton
        }
        // No top padding — the drag indicator brings its own, and the
        // card's top edge is this view's top edge.
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .sheet(isPresented: $showQueueSheet) {
            QueueView()
        }
        .onChange(of: isCollapsed) { _, collapsed in
            // Send the pager back to the album page on the way down. The
            // artwork that travels into the mini slot is this same view, so
            // leaving it on the EQ page would put a visualiser in the mini
            // bar's cover tile.
            if collapsed && showVisualizer {
                showVisualizer = false
                dragOffset = 0
            }
        }
        .task(id: artworkTaskID) {
            albumImage = await loadedArtwork()
            coverAccent = albumImage.flatMap(CoverColor.accent(from:))
            refreshCoverAccent()
        }
        // The extracted colour outlives a scheme flip; only the clamp on it
        // has to be redone.
        .onChange(of: colorScheme) { _, _ in refreshCoverAccent() }
    }

    private func refreshCoverAccent() {
        legibleCoverAccent = coverAccent?.legibleOnAppBackground(colorScheme)
    }

    private func loadedArtwork() async -> UIImage? {
        guard let album = playerService.currentTrack?.album else { return nil }
        if album.isLocal {
            guard let path = album.resolvedLocalCoverPath else { return nil }
            return UIImage(contentsOfFile: path)
        }
        let resolution = await albumArtService.resolveAlbumArt(for: album)
        albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
        return resolution.image
    }

    /// Ink for the collapsed pill's waveform.
    ///
    /// **Parked, not removed.** `legibleCoverAccent` — the cover's own colour,
    /// pushed to a luminance the current scheme can show — is still extracted
    /// and kept up to date above; it just isn't drawn with yet. Switching it
    /// back on is this one line:
    ///
    ///     legibleCoverAccent ?? themeService.accentColor
    private var miniWaveformColor: Color {
        themeService.accentColor
    }

    // MARK: - Chrome

    /// Grab indicator + album name. The indicator is now the honest signal it
    /// always looked like: dragging the card down is what closes it.
    private var header: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Text(playerService.currentTrack?.album?.name ?? "")
                .font(.uiSubheadline)
                .foregroundStyle(.secondary)
                .fadingTruncation(alignment: .center)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)
        }
        .nowPlayingChrome(progress)
    }

    /// Rides with the artwork instead of fading where it stands. The dots
    /// belong to the cover — they say which page of it you're on — so they
    /// travel to the cover's collapsed position and fade out there, rather
    /// than sitting still while everything around them moves.
    ///
    /// A slot with no mini form: nothing here exists in the collapsed pill, so
    /// there's nothing to cross-fade with. The travel comes from the slot, the
    /// fade from `nowPlayingChrome` on the content inside it.
    private var pageIndicator: some View {
        MorphSlot(progress: progress, cardSize: cardSize, miniFrame: MiniLayout.artwork) {
            HStack(spacing: 12) {
                // Album icon — small rounded square
                Image(systemName: "square.fill")
                    .font(.ui(8))
                    .foregroundColor(showVisualizer ? .secondary.opacity(0.4) : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                // EQ icon — small bar chart
                Image(systemName: "chart.bar.fill")
                    .font(.ui(10))
                    .foregroundColor(showVisualizer ? .primary : .secondary.opacity(0.4))
            }
            .nowPlayingChrome(progress)
        }
        // Matched to the artwork's collapsed width so the slot's own scale
        // factor is 1 — this travels, it doesn't shrink.
        .frame(width: MiniLayout.artworkSize, height: 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Centered live waveform — shows ±2 s around the playhead, scrolling
    /// right→left as playback progresses. Also acts as a high-precision
    /// scrubber: dragging maps ~20 ms per point, versus the full-width
    /// scrubber above where one point covers a much larger slice of the track.
    private var centeredWaveform: some View {
        // Built only once the pill is off the floor. This `Canvas` redraws on
        // every playhead tick, and it would go on doing that behind an opacity
        // of 0 for as long as the pill stayed collapsed. The frame stays either
        // way so the layout above and below it never moves.
        Group {
            if progress > 0.01 {
                CenteredWaveformView(
                    currentTime: playerService.isSeeking ? seekValue : playerService.currentTime,
                    duration: playerService.duration,
                    accentColor: themeService.accentColor,
                    samples: playerService.waveformSamples,
                    samplesPerSecond: playerService.waveformSamplesPerSecond,
                    onScrubStart: {
                        isScrubbing = true
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
                        isScrubbing = false
                    }
                )
            }
        }
        .frame(width: 200, height: 36)
        .contrastPanel(.centeredWaveform)
        .nowPlayingChrome(progress)
    }

    @ViewBuilder
    private var queueButton: some View {
        if !playerService.queue.isEmpty {
            Button {
                showQueueSheet = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.uiTitle3)
                    .foregroundStyle(.primary.opacity(0.6))
                    .overlay(alignment: .topTrailing) {
                        if !playerService.userQueue.isEmpty {
                            Text("\(playerService.userQueue.count)")
                                .font(.ui(10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                // Deepened like the other queue chips, or a
                                // pale accent swallows the count whole —
                                // worst here, where the digit is 10pt.
                                .background(themeService.accentColor.legibleUnderWhiteLabel, in: Capsule())
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .padding(.bottom, 16)
            .nowPlayingChrome(progress)
        }
    }

    // MARK: - Travelling components

    /// The cover travels like everything else, but its collapsed form is the
    /// mini bar's original 44pt tile rather than the expanded cover shrunk.
    ///
    /// Scaling was the obvious implementation and the wrong one: a `scaleEffect`
    /// of ~0.16 hands the compositor a 279pt raster to filter down to 44, and
    /// what comes back is crunchier than art drawn at 44pt to begin with. It
    /// also drags the expanded cover's own dressing along — a 20pt corner
    /// radius arriving as 3, a drop shadow arriving as a dark halo — none of
    /// which the mini tile ever had. Drawing the real tile at the real size
    /// settles all of it at once, and the two forms cross-fade mid-flight the
    /// way the text and scrubbers already do. Being the same square image at
    /// the same place, that cross-fade is close to invisible.
    private var artwork: some View {
        MorphSlot(
            progress: progress,
            cardSize: cardSize,
            miniFrame: MiniLayout.artwork,
            // The one component that scales: it's an image, so it does so
            // cleanly, and its two forms must agree in size mid-flight for the
            // cross-fade between them to go unnoticed.
            scales: true
        ) {
            coverPager
        } mini: {
            miniArtworkTile
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .padding(.horizontal, 24)
    }

    /// The mini bar's artwork tile, unchanged from before the pill existed:
    /// 6pt corners, an accent-tinted bed for art that hasn't loaded, no shadow.
    private var miniArtworkTile: some View {
        RoundedRectangle(cornerRadius: MiniLayout.artworkCornerRadius)
            .fill(themeService.accentColor.opacity(0.2))
            .frame(width: MiniLayout.artworkSize, height: MiniLayout.artworkSize)
            .overlay {
                Group {
                    if let albumImage {
                        Image(uiImage: albumImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: MiniLayout.artworkSize, height: MiniLayout.artworkSize)
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(themeService.accentColor)
                            .frame(width: MiniLayout.artworkSize, height: MiniLayout.artworkSize)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MiniLayout.artworkCornerRadius, style: .continuous))
    }

    private var trackInfo: some View {
        MorphSlot(progress: progress, cardSize: cardSize, miniFrame: MiniLayout.trackInfo) {
            VStack(spacing: 4) {
                MarqueeText(
                    text: playerService.currentTrack?.displayName ?? "Not Playing",
                    alignment: .center
                )
                .font(.uiTitle3.bold())
                subtitle(font: .uiSubheadline, alignment: .center)
            }
        } mini: {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: playerService.currentTrack?.displayName ?? "")
                    .font(.uiSubheadline.bold())
                subtitle(font: .uiCaption, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Title line + subtitle at the expanded sizes. Fixed, because the slot
        // is an empty placeholder — it has no content to measure.
        .frame(height: 52)
        .contrastPanel(.trackInfo)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func subtitle(font: Font, alignment: Alignment) -> some View {
        if let error = playerService.playbackError {
            Text(error)
                .font(font)
                .foregroundStyle(.red)
                .fadingTruncation(alignment: alignment)
        } else {
            Text(nowPlayingSubtitle)
                .font(font)
                .foregroundStyle(.secondary)
                .fadingTruncation(alignment: alignment)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            MorphSlot(progress: progress, cardSize: cardSize, miniFrame: MiniLayout.scrubber) {
                FullScrubber(
                    value: playerService.isSeeking ? seekValue : playerService.currentTime,
                    duration: playerService.duration,
                    accentColor: themeService.accentColor,
                    waveformSamples: playerService.waveformSamples,
                    onChanged: { newValue in beginOrContinueScrub(to: newValue) },
                    onEnded: { finalValue in endScrub(at: finalValue) }
                )
            } mini: {
                MiniScrubber(
                    value: playerService.isSeeking ? seekValue : playerService.currentTime,
                    duration: playerService.duration,
                    accentColor: miniWaveformColor,
                    waveformSamples: playerService.waveformSamples,
                    onChanged: { newValue in beginOrContinueScrub(to: newValue) },
                    onEnded: { finalValue in endScrub(at: finalValue) }
                )
            }
            .frame(height: FullScrubber.intrinsicHeight)

            HStack {
                Text(formatTime(playerService.isSeeking ? seekValue : playerService.currentTime))
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Text(formatTime(playerService.duration))
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .nowPlayingChrome(progress)
        }
        // The waveform and its two timestamps are one visual unit — panelling
        // the bars alone would leave the smallest, faintest text on the screen
        // outside the thing meant to be protecting it.
        .contrastPanel(.scrubber)
        .padding(.horizontal, 12)
    }

    /// Both scrubbers seek through the same state, so a scrub that starts
    /// mid-morph doesn't jump when hit-testing changes hands.
    private func beginOrContinueScrub(to newValue: TimeInterval) {
        if !playerService.isSeeking {
            seekValue = playerService.currentTime
            playerService.beginSeeking()
        }
        isScrubbing = true
        seekValue = newValue
        playerService.currentTime = newValue
    }

    private func endScrub(at finalValue: TimeInterval) {
        playerService.endSeeking(to: finalValue)
        isScrubbing = false
    }

    /// Spacing is sized to the pill, not chosen for looks: five controls
    /// (32 + ~30 + 60 + ~30 + 32 ≈ 184pt of glyph) have to clear the content
    /// width, which is the screen less the pill's 12pt insets and this view's
    /// 12pt padding — ≈327pt on a 375pt phone. 28pt gaps land at ~296; 40 (the
    /// old sheet's) didn't fit.
    private var transportControls: some View {
        HStack(spacing: 28) {
            Button {
                playerService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.uiCaption.bold())
                    .foregroundStyle(playerService.isShuffleOn ? .white : .secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        if playerService.isShuffleOn {
                            Circle()
                                .fill(themeService.accentColor)
                        }
                    }
            }
            .nowPlayingChrome(progress)

            Button {
                playerService.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.uiTitle2)
            }
            .nowPlayingChrome(progress)

            MorphSlot(
                progress: progress,
                cardSize: cardSize,
                miniFrame: MiniLayout.playPause,
                // Right-aligned against the row padding, exactly as the old
                // mini bar's trailing button was.
                miniAlignment: .trailing
            ) {
                Button {
                    playerService.togglePlayPause()
                } label: {
                    ZStack {
                        if playerService.isLoading {
                            LoadingIndicator(size: .large)
                        } else {
                            Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.ui(60))
                        }
                    }
                    .frame(width: 60, height: 60)
                }
            } mini: {
                Group {
                    if playerService.isLoading {
                        LoadingIndicator()
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
            }
            .frame(width: 60, height: 60)

            Button {
                playerService.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.uiTitle2)
            }
            .nowPlayingChrome(progress)

            Button {
                playerService.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.uiCaption.bold())
                    .foregroundStyle(playerService.repeatMode != .off ? .white : .secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        if playerService.repeatMode != .off {
                            Circle()
                                .fill(themeService.accentColor)
                        }
                    }
            }
            .nowPlayingChrome(progress)
        }
        .contrastPanel(.transport)
    }

    // MARK: - Album art / EQ pager

    /// Album art / EQ visualizer — custom two-page pager so we can track
    /// continuous swipe progress and morph the cover into an ambient "color
    /// halo" as the user scrolls toward the EQ page. A stock
    /// `TabView(.page)` would only expose the final commit, not the live drag
    /// fraction we need to drive the blur/corner/scale interpolation.
    ///
    /// The slot hands this a constant square — the expanded cover size — no
    /// matter how far the pill is open, so `pageWidth` never shrinks and the
    /// `Canvas` inside never redraws just because the card moved.
    private var coverPager: some View {
        GeometryReader { geo in
            let pageWidth = max(0, geo.size.width)
            // Combine the latched page (`showVisualizer`) with the live
            // finger offset to get a continuous 0…1 progress: 0 =
            // album cover, 1 = EQ visualizer.
            let committedOffset: CGFloat = showVisualizer ? -pageWidth : 0
            let totalOffset = committedOffset + dragOffset
            let rawProgress = pageWidth > 0 ? -totalOffset / pageWidth : 0
            let pageProgress = max(0, min(1, rawProgress))

            // Skip the whole subtree until GeometryReader has handed us a real
            // width. On the first layout pass `pageWidth` is 0, and the EQ
            // visualizer's internal `.padding(...)` then resolves to a negative
            // content frame — which is exactly what triggers the "Invalid frame
            // dimension" console spam.
            if pageWidth > 0 {
                ZStack {
                    // Cover → halo morph. Same image the whole time; as
                    // progress climbs toward 1 we scale it up slightly,
                    // grow the corner radius, and crank the blur. Because
                    // the blur is applied AFTER the rounded-rect clip, the
                    // Gaussian spread feathers the cover's silhouette
                    // outward — exactly the "halo in the shape of the
                    // album" effect the earlier static background had.
                    albumHaloMorph(pageProgress: pageProgress, pageWidth: pageWidth)
                        // Drop shadow fades out as the cover dissolves into
                        // a soft halo — a blurred glow doesn't need a hard
                        // shadow under it — and again as the pill collapses:
                        // the mini bar's artwork tile never had one, and at
                        // 0.16 scale it reads as a dark halo around the tile
                        // rather than as a shadow under a cover.
                        .shadow(color: .black.opacity(0.35 * (1 - pageProgress) * progress),
                                radius: 20, y: 10)

                    // EQ visualizer slides in from the right and fades up
                    // as the halo forms behind it. Uniform padding, unlike the
                    // axis-labelled chart this replaced: the grid has to stay
                    // square, so it can't be given more room in one direction.
                    // Built only once the page is at least partly on screen.
                    // The grid registers its own analyzer consumer while it
                    // exists, so its lifetime *is* the FFT tap's lifetime —
                    // leave it built behind the cover and the tap runs the
                    // whole time the player is open, for a grid nobody sees.
                    if pageProgress > 0 {
                        PixelEQGrid(
                            isPlaying: playerService.isPlaying,
                            // Fills the page rather than taking a fixed size.
                            size: nil,
                            // One column per analyzer band.
                            side: 16
                        )
                        .padding(16)
                        .frame(width: pageWidth, height: pageWidth)
                        .opacity(pageProgress)
                        .offset(x: (1 - pageProgress) * pageWidth * 0.35)
                        .allowsHitTesting(pageProgress > 0.5)
                    }
                }
                .frame(width: pageWidth, height: pageWidth)
                // Horizontal-only pan recognizer bridged in from UIKit.
                // SwiftUI's `DragGesture` — even via `.simultaneousGesture`
                // — still claims the touch in a way that suppresses a
                // vertical drag on an ancestor, which is how the pill is
                // collapsed. A UIKit pan with `gestureRecognizerShouldBegin`
                // rejecting vertical motion and `shouldRecognizeSimultaneouslyWith`
                // returning true lets the pill handle vertical drags normally
                // while we still drive the album→halo morph horizontally.
                .overlay(
                    HorizontalPagerGesture(
                        onChanged: { dx in
                            var t = dx
                            if showVisualizer, t < 0 { t /= 3 }
                            if !showVisualizer, t > 0 { t /= 3 }
                            dragOffset = t
                        },
                        onEnded: { dx, predictedDx in
                            let positionThreshold = pageWidth * 0.10
                            let velocityThreshold = pageWidth * 0.40
                            let shouldAdvance =
                                dx < -positionThreshold ||
                                predictedDx < -velocityThreshold
                            let shouldRetreat =
                                dx > positionThreshold ||
                                predictedDx > velocityThreshold
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if showVisualizer, shouldRetreat {
                                    showVisualizer = false
                                } else if !showVisualizer, shouldAdvance {
                                    showVisualizer = true
                                }
                                dragOffset = 0
                            }
                        },
                        onTap: {
                            // Tap-to-open-album only engages on the album
                            // page; on the EQ page the tap is a no-op.
                            guard pageProgress < 0.5,
                                  let album = playerService.currentTrack?.album else { return }
                            onOpenAlbum?(album)
                        }
                    )
                    // Paging is only on the table once the card has stopped
                    // moving. Below that the cover is in flight and a touch on
                    // it means "expand" (or nothing) — and while collapsed the
                    // recognizer would otherwise swallow taps on the mini
                    // artwork before the card ever saw them.
                    .allowsHitTesting(progress > 0.99)
                )
            }
        }
    }

    /// The album cover that morphs into the ambient halo as `pageProgress`
    /// climbs from 0 (album page) to 1 (EQ page). Kept as a single view so
    /// the transformation stays continuous — there's no crossfade between
    /// two different images, just one image whose blur/corner/scale is
    /// driven by scroll position.
    ///
    /// Named for the *pager*, not the pill: this is the horizontal swipe
    /// between cover and visualiser, nothing to do with `progress`.
    @ViewBuilder
    private func albumHaloMorph(pageProgress: CGFloat, pageWidth: CGFloat) -> some View {
        // Corner radius has to be drawn *pre-scale*. The slot shows this view
        // at 44/pageWidth (≈0.16) once the pill is collapsed, so a 20pt radius
        // arrives on screen as ~3pt and the tile looks squarer than the mini
        // bar's 6pt one ever did. Dividing by the same factor puts the
        // collapsed corner back exactly where it was.
        let collapsedRadius = MiniLayout.artworkCornerRadius * pageWidth / MiniLayout.artworkSize
        let expandedRadius = 20 + 12 * pageProgress
        let cornerRadius = collapsedRadius + (expandedRadius - collapsedRadius) * progress
        // Both halo effects are scaled by the pill as well as the pager, so a
        // collapse that starts on the EQ page doesn't shrink a blurred glow
        // into the artwork tile.
        let blurRadius = pageProgress * 28 * progress
        // Grow slightly as we morph so the halo reads as a little wider
        // than the original cover, matching Apple Music/Spotify's feel.
        let scale = 1 + 0.12 * pageProgress * progress

        Group {
            if let albumImage {
                Image(uiImage: albumImage)
                    .resizable()
                    .scaledToFill()
            } else {
                // Same radius as the clip below, or the coverless tile keeps
                // the square corners the clip was widened to hide.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                themeService.accentColor.opacity(0.6),
                                themeService.accentColor.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.ui(80))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        }
        .frame(width: pageWidth, height: pageWidth)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(scale)
        .blur(radius: blurRadius)
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

    /// Fixed overall height — the two ears plus the gap between them. Exposed
    /// because the morph slot that carries this scrubber is an empty
    /// placeholder and has to be told how much room to reserve for it.
    static let intrinsicHeight: CGFloat = 62

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
        // Asserts the constant above still describes the geometry below it.
        assert(Self.intrinsicHeight == earHeight * 2 + centerGap)
        return earHeight * 2 + centerGap
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

// MARK: - Horizontal Pager Gesture (UIKit bridge)

/// UIKit-backed gesture recognizer overlay that captures horizontal pans
/// and taps on the album pager, but deliberately refuses to begin for
/// vertical drags so the sheet's built-in swipe-to-dismiss recognizer can
/// claim those instead. A SwiftUI `DragGesture`, even when used via
/// `simultaneousGesture`, still locks the touch enough to block the
/// sheet's UIKit pan recognizer from recognizing a vertical flick; the
/// only reliable workaround is to own the recognizer ourselves and set
/// its delegate.
private struct HorizontalPagerGesture: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    /// Called once at drag end with the raw translation and a projected
    /// "where would this finger have stopped" translation computed from
    /// release velocity — mirrors SwiftUI's `predictedEndTranslation` so
    /// the call site can implement velocity-based page commits.
    var onEnded: (CGFloat, CGFloat) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded, onTap: onTap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        var onTap: () -> Void

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onTap: @escaping () -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onTap = onTap
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            let v = gr.velocity(in: gr.view)
            switch gr.state {
            case .changed:
                onChanged(t.x)
            case .ended, .cancelled, .failed:
                // Project where the finger *would* have landed if it kept
                // decelerating at the current release velocity. 0.2 s is
                // roughly what UIScrollView uses for short paging flicks.
                let predicted = t.x + v.x * 0.2
                onEnded(t.x, predicted)
            default:
                break
            }
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            onTap()
        }

        // Only let the pan begin if the initial motion is primarily
        // horizontal. A vertical-dominant start leaves this recognizer in
        // `.possible` forever, so the sheet's pan recognizer wins and
        // swipe-to-dismiss works normally.
        func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
            guard let pan = gr as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            // Require a tiny minimum distance before committing to a
            // direction — otherwise iOS calls this with (0,0) and we'd
            // greenlight everything.
            if abs(t.x) < 2 && abs(t.y) < 2 { return false }
            return abs(t.x) > abs(t.y)
        }

        // Coexist with every other recognizer in the tree — crucially
        // including the sheet's swipe-to-dismiss pan — so that our "refuse
        // to begin for vertical" decision actually lets the other
        // recognizer take over instead of both being stuck waiting.
        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
