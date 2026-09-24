import SwiftUI

/// A screen-filling grid of round pixels rippling like struck water, each dot
/// sized by how lit it is — and, over the top of it, a machine trying to work
/// out what the water is doing.
///
/// Every bit of the shape and colour comes from `PixelRipple.metal`; this view
/// only decides how big a pixel is and supplies the clock. The clock is then
/// handed to a second consumer, `FieldAnalysisRunner`, which samples the same
/// panel at 12 Hz and runs a detector-tracker over it — see
/// `FieldAnalysis.swift`. This view owns that loop because it owns the two
/// things it needs, the lattice and the clock, and because the analysis is
/// meaningless without the field under it.
///
/// The dots grow and shrink with the water — see the note at the top of the
/// shader. `PixelEQGrid` is the app's other pixel grid and keeps its cells a
/// fixed size, because that one is a readout you're meant to count and this one
/// is a display you're meant to read through.
struct PixelRippleField: View {
    /// Roughly how big one cell should be, in points — the dot inside it is
    /// this at its brightest and a speck at its darkest. Rounded per-device by
    /// `fittedCell` so a whole number of columns spans the width.
    var pixelSize: CGFloat = 12

    /// `TimelineView(.animation)` for the same reason `SpinningPlasmaOrb` uses
    /// it — the motion is continuous and unbounded, so there's no keyframe pair
    /// to animate between, just elapsed time.
    ///
    /// Measured from here rather than the reference date for the precision
    /// reason spelled out in `DiscoHouse`: that's ~7.7e8, and the `float` the
    /// shader receives carries about seven significant digits, so the
    /// fractional part would quantise to steps coarser than a frame.
    @State private var start = Date()

    /// Which field this launch shows: where the eight drops land.
    ///
    /// Drawn once per view, so a cold launch is a different screen every time
    /// rather than the same eight splashes in the same eight places. It is
    /// only the *placement* that varies — the timing, the speed and the ripple
    /// pitch are the choreography the whole screen is tuned around, and the
    /// fill's shape is the same every run.
    ///
    /// Taken from the clock, and then kept small (see `surfaceAt`, which
    /// explains why a big seed would break slot recycling outright). Sub-second
    /// digits rather than whole seconds, because two launches a second apart
    /// should not be adjacent fields.
    ///
    /// **Both consumers get this same value.** The shader draws with it and
    /// the analysis samples with it; hand them different seeds and the overlay
    /// is measuring water that is not on screen.
    @State private var seed = Float(
        Int(Date().timeIntervalSince1970 * 1000) % 4096
    )

    /// Whether to run the analysis layer over the field. On for the launch
    /// screen, which is the only place this view is used — a parameter rather
    /// than an assumption, since the field is the thing that works alone and
    /// the overlay is the thing that can't.
    var showsAnalysis: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The inference loop. `@State` rather than injected: it holds no app
    /// state, it lives exactly as long as this view, and two fields on screen
    /// would each want their own tracker.
    @State private var runner = FieldAnalysisRunner()

    /// Floors under the overlay's label clearance from the screen's ends. The
    /// field bleeds under the sensor housing and the home indicator because it
    /// is water; a track's name can't, and `safeAreaInsets` reports zero here
    /// — the splash ignores the safe area, which is what makes the water
    /// full-bleed in the first place.
    private static let labelTop: CGFloat = 52
    private static let labelBottom: CGFloat = 34

    /// The frame Reduce Motion holds. Late in the fill, where most slots have
    /// fired, so the still shows a full field rather than the single drop that
    /// exists at zero.
    private static let heldFrame: Double = 2.1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cell = Self.fittedCell(target: pixelSize, width: size.width)

            ZStack {
                if reduceMotion {
                    // No `TimelineView` at all rather than a frozen one: this
                    // is a full-screen fragment shader, and there's no reason
                    // to keep paying for it every frame to redraw the same
                    // square.
                    field(size: size, cell: cell, time: Self.heldFrame)
                } else {
                    TimelineView(.animation) { timeline in
                        field(size: size, cell: cell, time: timeline.date.timeIntervalSince(start))
                    }
                }

                // Only once a tick has landed — there is nothing to draw
                // until the detector has run at least one frame.
                if showsAnalysis, let frame = runner.frame {
                    FieldAnalysisOverlay(
                        frame: frame,
                        safeTop: max(proxy.safeAreaInsets.top, Self.labelTop),
                        safeBottom: max(proxy.safeAreaInsets.bottom, Self.labelBottom)
                    )
                }
            }
            // Keyed on the lattice, not on appearance: a rotation or a split
            // view changes the grid the analysis is indexing, and the runner
            // has to be told rather than left describing the old one.
            .task(id: TaskID(size: size, cell: cell, reduceMotion: reduceMotion)) {
                guard showsAnalysis else { return }
                if reduceMotion {
                    // The same pipeline, stepped up to the frame the field is
                    // holding — so the still carries a real analysis of itself
                    // rather than a first-tick picture of one.
                    runner.runStill(
                        size: size, cell: cell, upTo: Self.heldFrame, seed: seed
                    )
                } else {
                    runner.run(size: size, cell: cell, start: start, seed: seed)
                }
            }
            .onDisappear { runner.stop() }
        }
        .accessibilityHidden(true)
    }

    /// What a restart depends on. `.task(id:)` cancels and re-runs on any
    /// change to this, which is exactly the set of things that invalidates a
    /// running loop.
    private struct TaskID: Equatable {
        let size: CGSize
        let cell: CGFloat
        let reduceMotion: Bool
    }

    private func field(size: CGSize, cell: CGFloat, time: Double) -> some View {
        Rectangle()
            .fill(.white)
            .colorEffect(
                ShaderLibrary.pixelRipple(
                    .float2(size.width, size.height),
                    .float(cell),
                    .float(time),
                    .float(seed)
                )
            )
    }

    /// The pixel size nearest `target` that divides `width` evenly.
    ///
    /// Only the width is squared up. Cells have to stay square, so one axis has
    /// to be the one that ends in a partial row — and it should be the vertical
    /// one, because a half-width column against the side of the screen is
    /// plainly visible where a half-height row under the home indicator is not.
    private static func fittedCell(target: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return target }
        let columns = max(1, (width / target).rounded())
        return width / columns
    }
}

#Preview {
    PixelRippleField()
        .ignoresSafeArea()
}
