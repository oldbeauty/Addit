import SwiftUI

/// The one glass surface that is both the mini player and the full player.
///
/// There is no sheet. Collapsed and expanded are the same pill at two heights:
/// the width, the horizontal inset and the 4pt gap above the bottom safe area
/// never change, so the card only ever grows *upward* — the mini player is the
/// bottom edge of the full player.
///
/// ## Why the layout works the way it does
///
/// The expanded content is laid out **once, at its full height, always** — even
/// when the card is 96pt tall — and the card simply clips it. That is not a
/// detail; it is the whole design:
///
/// - Laying the full player out at intermediate heights makes its paddings
///   resolve against a height smaller than they are, which produces negative
///   content frames by the thousand ("Invalid frame dimension (negative or
///   non-finite)"). The log traffic alone is enough to make the animation
///   stutter.
/// - Every intermediate height is also a full relayout of the cover pager's
///   `GeometryReader`, three `Canvas` waveforms and the marquee. Transforms
///   (`scaleEffect`, `offset`, `opacity`) are not: they skip layout entirely.
///
/// So nothing here resizes anything to animate it. `progress` drives the card's
/// height and a set of transforms, and that's all.
///
/// ## How components travel
///
/// `MorphSlot` reserves a component's expanded position inside the full layout
/// and then draws that component at an *interpolated* position between there
/// and where the same component sits in the mini bar. There is exactly one
/// artwork view, and it really does fly between the two states — it is not two
/// views trading places. Text and the scrubbers, whose two forms are genuinely
/// different drawings, travel *together* along the same interpolated path and
/// cross-fade en route, which reads as one element changing rather than one
/// being swapped for another.
struct NowPlayingPill: View {
    /// Called when the user taps the album artwork on the expanded page. The
    /// host pushes the album; the pill collapses itself.
    var onOpenAlbum: (Album) -> Void

    @State private var isExpanded = false
    /// Raised by whichever scrubber is live. Tap-to-expand has to ignore the
    /// touch-up that ends a scrub, or letting go of the playhead opens the
    /// player.
    @State private var isScrubbing = false
    /// Live downward drag distance while collapsing by hand. Always ≥ 0 —
    /// upward drags do nothing, since the card is already at full height when
    /// the gesture can start.
    @State private var dragOffset: CGFloat = 0

    /// Coordinate space of the card itself. `MorphSlot` resolves both its
    /// expanded and collapsed frames here so the two are directly comparable.
    static let cardSpace = "nowPlayingCard"

    /// What the collapsed pill occupies above the bottom safe area — the card
    /// plus the gap under it. Screens the pill overlays reserve this much
    /// bottom safe area so scrolled-to-end content rests above it, not under.
    static let overlayHeight: CGFloat = MiniLayout.cardHeight + bottomInset

    private static let horizontalInset: CGFloat = 12
    private static let bottomInset: CGFloat = 4

    private let collapsedCorner: CGFloat = 20
    private let expandedCorner: CGFloat = 38

    /// Drag distance (or projected flick distance) past which release collapses
    /// instead of springing back.
    private let dismissDistance: CGFloat = 140
    private let dismissFlickDistance: CGFloat = 420

    private var morphAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 0.85)
    }

    var body: some View {
        GeometryReader { geo in
            // `geo` is already inset by the safe area, so the expanded card
            // stops at the top safe-area boundary and stays a pill.
            let expandedHeight = max(MiniLayout.cardHeight, geo.size.height - Self.bottomInset)
            // Travel available to the top edge, and so the drag's full range.
            let span = max(1, expandedHeight - MiniLayout.cardHeight)
            let target = isExpanded ? min(1, max(0, 1 - dragOffset / span)) : 0
            // Constant for the whole gesture: the card's frame never changes,
            // only the silhouette drawn inside it.
            let cardSize = CGSize(
                width: max(0, geo.size.width - 2 * Self.horizontalInset),
                height: expandedHeight
            )

            ZStack(alignment: .bottom) {
                // Only a sliver of this shows (the side margins and the status
                // bar strip) — enough to seat the card in front of the library
                // rather than floating on it, and somewhere to tap that isn't
                // a control.
                Color.black.opacity(0.28 * target)
                    .ignoresSafeArea()
                    .allowsHitTesting(isExpanded)
                    .onTapGesture { collapse() }

                MorphProgress(progress: target) { progress in
                    card(cardSize: cardSize, span: span, progress: progress)
                }
            }
        }
    }

    @ViewBuilder
    private func card(cardSize: CGSize, span: CGFloat, progress: CGFloat) -> some View {
        let shape = PillShape(
            topInset: span * (1 - progress),
            cornerRadius: collapsedCorner + (expandedCorner - collapsedCorner) * progress
        )

        NowPlayingView(
            progress: progress,
            cardSize: cardSize,
            isScrubbing: $isScrubbing,
            onOpenAlbum: { album in
                onOpenAlbum(album)
                collapse()
            }
        )
        // One fixed frame, at full height, for every value of `progress`. The
        // collapse is drawn by `shape` alone — see `PillShape`.
        .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
        .coordinateSpace(.named(Self.cardSpace))
        .glassEffect(.regular, in: shape)
        // Applied *after* the glass, so it lands underneath it.
        .backgroundPreferenceValue(ContrastPanelAnchors.self) { anchors in
            contrastPanels(anchors, progress: progress)
        }
        // Clips drawing *and* hit-testing, so the expanded content hidden above
        // the collapsed pill's top edge can't be touched either — and so these
        // panels can't spill past the pill's edge.
        .clipShape(shape)
        .contentShape(shape)
        // Tap-to-expand belongs on the card, not on a backstop behind the
        // content: a parent gesture fires for every touch a child didn't
        // claim, so the artwork, the title and the empty space all open the
        // player while the scrubber and the play button keep their own
        // touches. That's how the mini bar behaved before it became the pill,
        // down to the guard against the touch-up that ends a scrub.
        .onTapGesture {
            guard !isExpanded, !isScrubbing else { return }
            expand()
        }
        // `.subviews` while collapsed leaves the mini scrubber's own drag
        // working and keeps this one out of the way; expanded, both are live
        // and the scrubbers still win their own touches as child gestures.
        .gesture(dismissDrag, including: isExpanded ? .all : .subviews)
        .padding(.horizontal, Self.horizontalInset)
        .padding(.bottom, Self.bottomInset)
    }

    /// Panels that sit behind the components whose legibility is otherwise at
    /// the mercy of whatever the glass happens to be over.
    ///
    /// **Under the glass, not over it.** They're attached as a `background` of
    /// the already-glassed card, which puts them between the library and the
    /// material. Two things follow, both wanted: the material has a flat colour
    /// to sample instead of a grid of album covers, so the contrast problem is
    /// solved at its source rather than papered over; and the panels come back
    /// blurred, so the pill still reads as one continuous surface instead of
    /// four rectangles stuck to it. (A blur of a flat colour is that same flat
    /// colour — only the edges feather, which is the part worth softening.)
    ///
    /// Positions come from anchors the components publish themselves. Their
    /// slots are fixed by the expanded layout, so these are constant and don't
    /// chase anything during a drag; the panels only fade.
    @ViewBuilder
    private func contrastPanels(
        _ placements: [ContrastPanel: ContrastPanelPlacement],
        progress: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            ForEach(Array(placements.keys), id: \.self) { panel in
                if let placement = placements[panel] {
                    let bounds = proxy[placement.anchor]
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.appBackground.opacity(0.55))
                        .frame(
                            width: bounds.width + Self.panelInset * 2,
                            height: bounds.height + Self.panelInset
                        )
                        .position(x: bounds.midX, y: bounds.midY)
                        // The component's own say, on top of the shared fade
                        // below — a panel whose component has gone has to go
                        // with it, not linger at its last known frame.
                        .opacity(placement.opacity)
                }
            }
        }
        // Same curve as the rest of the expanded-only chrome, so they arrive
        // and leave with the controls they back rather than on their own.
        .opacity(Double(min(1, max(0, (progress - 0.45) / 0.45))))
        .allowsHitTesting(false)
    }

    /// How far each panel is grown past the component it backs — full measure
    /// horizontally, half vertically, since these components are wider than
    /// they are tall and a tall panel reads as a box.
    private static let panelInset: CGFloat = 10

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag in
                guard isExpanded else { return }
                // No animation wrapper: the card tracks the finger exactly.
                dragOffset = max(0, drag.translation.height)
            }
            .onEnded { drag in
                guard isExpanded else { return }
                let travelled = drag.translation.height
                let projected = drag.predictedEndTranslation.height
                withAnimation(morphAnimation) {
                    if travelled > dismissDistance || projected > dismissFlickDistance {
                        isExpanded = false
                    }
                    dragOffset = 0
                }
            }
    }

    private func expand() {
        withAnimation(morphAnimation) { isExpanded = true }
    }

    private func collapse() {
        withAnimation(morphAnimation) {
            isExpanded = false
            dragOffset = 0
        }
    }
}

// MARK: - Silhouette

/// The pill's outline: a rounded rectangle whose **top edge** moves while its
/// bottom, its sides and its width stay exactly where they are.
///
/// Collapsing by animating the card's `frame` height — the obvious way, and the
/// first way this was built — costs a full layout pass, a resize of the glass
/// material's backdrop blur, and a fresh round of geometry propagation on every
/// single touch event of the drag. `GeometryReader` also publishes a pass late,
/// so the travelling components ended up trailing the card's edge by a frame.
/// That is the jitter.
///
/// Drawing the collapse as a shape instead means the card's frame is constant:
/// only a mask, a clip and a hit region change per frame, every measurement
/// inside stays valid for the whole gesture, and nothing relayouts.
struct PillShape: Shape {
    /// Distance from the top of the (fixed) frame down to the pill's visible
    /// top edge. 0 is fully expanded.
    var topInset: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, cornerRadius) }
        set {
            topInset = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let inset = min(max(0, topInset), rect.height)
        let body = CGRect(
            x: rect.minX,
            y: rect.minY + inset,
            width: rect.width,
            height: rect.height - inset
        )
        return Path(
            roundedRect: body,
            cornerRadius: min(cornerRadius, min(body.width, body.height) / 2),
            style: .continuous
        )
    }
}

/// Re-evaluates its content once per animation frame with an *interpolated*
/// `progress`, rather than once with the destination value.
///
/// Everything about the morph is a function of `progress` — the silhouette,
/// which form of each component is on screen, which are cheap enough to keep
/// alive. That only works if `progress` is a real per-frame quantity.
/// Conforming to `Animatable` is what makes SwiftUI hand it back interpolated;
/// without it a spring would jump the value to its destination immediately and
/// animate only the individual modifiers underneath, which snaps every `if` in
/// the tree — the collapsed forms would vanish on contact instead of fading.
/// Not private: the queue morph inside `NowPlayingView` needs the same
/// treatment for the same reason, and re-deriving it there would be two copies
/// of a subtlety that is easy to get wrong once.
struct MorphProgress<Content: View>: View, Animatable {
    var progress: CGFloat
    var content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        content(progress)
    }
}

// MARK: - Collapsed geometry

/// Where each travelling component sits when the pill is collapsed, in the
/// card's coordinate space.
///
/// These are derived, not chosen: they reproduce the mini bar's old stack —
/// 8pt top padding, a 28pt scrubber, then a 16pt-inset row of 44pt artwork,
/// title block and play button under 8pt of vertical padding. Everything is
/// measured **up from the card's bottom edge**, which is the one edge that
/// never moves, so these frames stay correct at any card height.
/// `nonisolated` because these are handed to `MorphSlot` as plain closures and
/// evaluated during layout; the project defaults to `MainActor` isolation, and
/// pure geometry has no business being actor-bound.
nonisolated enum MiniLayout {
    /// 8 (top pad) + 28 (scrubber) + 8 + 44 (artwork row) + 8.
    static let cardHeight: CGFloat = 96

    static let sidePadding: CGFloat = 16
    static let artworkSize: CGFloat = 44
    static let artworkCornerRadius: CGFloat = 6
    static let scrubberHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 12
    /// Box for the mini play/pause glyph. Deliberately wider than the glyph:
    /// the old row right-aligned the button against the padding, so this box is
    /// drawn `.trailing` and only its **right** edge has to be exact. Guessing
    /// the glyph's width would move the button, which is precisely the drift
    /// that centre-anchoring it caused.
    static let playSize: CGFloat = 32

    /// Centre line of the artwork row, measured up from the card's bottom.
    private static let rowCenterFromBottom: CGFloat = 30

    static func artwork(in card: CGSize) -> CGRect {
        CGRect(
            x: sidePadding,
            y: card.height - rowCenterFromBottom - artworkSize / 2,
            width: artworkSize,
            height: artworkSize
        )
    }

    static func scrubber(in card: CGSize) -> CGRect {
        CGRect(
            x: sidePadding,
            y: card.height - cardHeight + 8,
            width: max(1, card.width - 2 * sidePadding),
            height: scrubberHeight
        )
    }

    static func playPause(in card: CGSize) -> CGRect {
        CGRect(
            x: card.width - sidePadding - playSize,
            y: card.height - rowCenterFromBottom - playSize / 2,
            width: playSize,
            height: playSize
        )
    }

    static func trackInfo(in card: CGSize) -> CGRect {
        let leading = sidePadding + artworkSize + rowSpacing
        let trailing = sidePadding + playSize + rowSpacing
        let height: CGFloat = 36
        return CGRect(
            x: leading,
            y: card.height - rowCenterFromBottom - height / 2,
            width: max(1, card.width - leading - trailing),
            height: height
        )
    }
}

// MARK: - Morphing slot

/// One component that exists in both player states, drawn once at a position
/// interpolated between them.
///
/// The slot itself is an empty placeholder: it takes whatever frame the
/// expanded layout gives it, which is how the expanded position is known
/// without hard-coding it. Its content is then drawn in an overlay, positioned
/// between that frame and `miniFrame`, and **transformed** rather than resized
/// — the content is always laid out at its own natural size, so no amount of
/// dragging can squeeze a padding negative or force a `Canvas` to redraw.
///
/// Two forms are supported:
/// - `shared:` — one view that scales and travels (the album artwork).
/// - `expanded:`/`mini:` — two genuinely different drawings that travel along
///   the same path and cross-fade midway (text, the scrubbers, play/pause).
struct MorphSlot<Expanded: View, Mini: View>: View {
    private let progress: CGFloat
    private let cardSize: CGSize
    private let miniFrame: (CGSize) -> CGRect
    /// How the mini form sits inside `miniFrame`. The collapsed row aligned
    /// its contents against the padding, not against each other's centres, so
    /// a box that's a few points wider than its glyph must still put that
    /// glyph on the correct edge.
    private let miniAlignment: Alignment
    /// Whether the two forms are scaled toward each other's size as they
    /// travel.
    ///
    /// Off by default, and deliberately: `scaleEffect` on text or an SF Symbol
    /// re-rasterises the glyphs at every intermediate scale, and the hinting
    /// and subpixel positioning shift as it goes — the type visibly shimmers,
    /// which is most obvious during a slow drag. Where the two forms differ in
    /// size only because they differ in *font*, the cross-fade already conveys
    /// it and the scale adds nothing but the shimmer. Artwork is the exception:
    /// it's an image, it scales cleanly, and its two forms have to agree in
    /// size for their cross-fade to be invisible.
    private let scales: Bool
    private let expanded: Expanded
    private let mini: Mini?

    init(
        progress: CGFloat,
        cardSize: CGSize,
        miniFrame: @escaping (CGSize) -> CGRect,
        miniAlignment: Alignment = .center,
        scales: Bool = false,
        @ViewBuilder expanded: () -> Expanded,
        @ViewBuilder mini: () -> Mini
    ) {
        self.progress = progress
        self.cardSize = cardSize
        self.miniFrame = miniFrame
        self.miniAlignment = miniAlignment
        self.scales = scales
        self.expanded = expanded()
        self.mini = mini()
    }

    init(
        progress: CGFloat,
        cardSize: CGSize,
        miniFrame: @escaping (CGSize) -> CGRect,
        scales: Bool = false,
        @ViewBuilder shared: () -> Expanded
    ) where Mini == EmptyView {
        self.progress = progress
        self.cardSize = cardSize
        self.miniFrame = miniFrame
        self.miniAlignment = .center
        self.scales = scales
        self.expanded = shared()
        self.mini = nil
    }

    /// Cross-fade weight. Held at the ends and swapped through the middle of
    /// the travel, so each form is fully itself while it's the one you're
    /// looking at and the swap happens while everything is in motion.
    private var fade: CGFloat {
        min(1, max(0, (progress - 0.2) / 0.6))
    }

    var body: some View {
        Color.clear
            // The placeholder reserves space and nothing else — it must not
            // eat taps meant for the card underneath.
            .allowsHitTesting(false)
            .overlay {
                GeometryReader { geo in
                    let slot = geo.frame(in: .named(NowPlayingPill.cardSpace))
                    let target = miniFrame(cardSize)
                    let width = target.width + (slot.width - target.width) * progress
                    let centerX = target.midX + (slot.midX - target.midX) * progress
                    let centerY = target.midY + (slot.midY - target.midY) * progress

                    ZStack {
                        // Each form is dropped outright once it's invisible,
                        // not just faded to zero. These are `Canvas` waveforms
                        // driven by the playhead: left in the tree they would
                        // redraw many times a second behind an opacity of 0,
                        // for the entire time the pill sits collapsed.
                        if mini == nil || fade > 0 {
                            expanded
                                .frame(width: slot.width, height: slot.height)
                                .scaleEffect(scales && slot.width > 0 ? width / slot.width : 1)
                                .opacity(mini == nil ? 1 : Double(fade))
                                .allowsHitTesting(progress > 0.5)
                        }

                        if let mini, fade < 1 {
                            mini
                                .frame(width: target.width, height: target.height, alignment: miniAlignment)
                                .scaleEffect(scales && target.width > 0 ? width / target.width : 1)
                                .opacity(Double(1 - fade))
                                .allowsHitTesting(progress <= 0.5)
                        }
                    }
                    // Positions are in card space; the reader's own origin is
                    // the slot, so shift by it to get back to local space.
                    .position(x: centerX - slot.minX, y: centerY - slot.minY)
                }
            }
    }
}

// MARK: - Contrast panels

/// Regions of the expanded player that get a panel behind them.
enum ContrastPanel: Hashable {
    case trackInfo
    case scrubber
    case centeredWaveform
    case transport
}

/// Where a panelled component ended up, and how much of its panel it currently
/// wants.
///
/// The opacity is carried here rather than applied by the pill because only the
/// component knows when it has stopped being on screen for reasons of its own —
/// queue mode collapses the track info, and a panel left behind at the anchor
/// of a zero-height row is a rectangle sitting in the middle of nothing.
struct ContrastPanelPlacement {
    var anchor: Anchor<CGRect>
    var opacity: Double
}

/// Collects where each panelled component ended up, so the pill can draw
/// behind them without duplicating the expanded layout.
struct ContrastPanelAnchors: PreferenceKey {
    static let defaultValue: [ContrastPanel: ContrastPanelPlacement] = [:]

    static func reduce(
        value: inout [ContrastPanel: ContrastPanelPlacement],
        nextValue: () -> [ContrastPanel: ContrastPanelPlacement]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this component as wanting a contrast panel behind it. The panel is
    /// drawn by `NowPlayingPill`, not here — see `NowPlayingPill.contrastPanels`
    /// for why it can't be a plain `.background`.
    func contrastPanel(_ panel: ContrastPanel, opacity: Double = 1) -> some View {
        anchorPreference(key: ContrastPanelAnchors.self, value: .bounds) {
            [panel: ContrastPanelPlacement(anchor: $0, opacity: opacity)]
        }
    }
}

// MARK: - Expanded-only chrome

extension View {
    /// For the parts of the full player that have nowhere to go when the pill
    /// collapses. They stay exactly where the expanded layout put them (moving
    /// them would mean relayout) and simply fade, late enough that the mini
    /// state is clean well before the card reaches it.
    func nowPlayingChrome(_ progress: CGFloat) -> some View {
        opacity(Double(min(1, max(0, (progress - 0.45) / 0.45))))
            .allowsHitTesting(progress > 0.9)
    }
}
