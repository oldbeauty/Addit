import SwiftUI

/// "ADDIT" as a solid slab read out in false colour — the app's wordmark
/// wherever it appears at full size.
///
/// Drawn in two places: the sign-in screen and the launch splash. It lives here
/// so those two can't drift apart, for the same reason `LoadingSplashView` does
/// — the splash's own wordmark used to be a plain `Text` and the two marks
/// showed the app under two different names' worth of styling within a second
/// of each other.
///
/// Everything about it comes from `Wordmark.metal`; this view only decides how
/// big a cap height is and supplies the clock. That includes the letterforms,
/// which are polygons in the shader rather than a font: the mark wants a raked
/// italic cut this heavy, with folded angular bowls, and no face iOS ships is
/// within reach of that. An earlier cut of these letterforms gave the A and
/// the T spurs — a spear, barbs, a rising blade — and they read as two letters
/// in a different font from the three between them; every terminal stops flat
/// at the cap or the baseline now. The cut before that set
/// Hoefler Text Black — chosen by elimination, since iOS has no blackletter at
/// all and a heavy gothic serif was the nearest thing available — under a
/// stack of offset copies standing in for depth. Drawing the letters as
/// distance fields instead is what lets them be extruded into an actual solid
/// and raymarched, so the extrusion's walls are surfaces that catch the room
/// rather than a fan of darker duplicates.
struct AdditWordmark: View {
    /// Cap height of the letters, in points. Everything else is derived from
    /// it, so the mark scales as one object.
    var size: CGFloat = 34

    /// How much extra light falls on the mark, 0…1 — the splash uses it, the
    /// sign-in screen doesn't.
    ///
    /// Scales the palette and the halo together. Not a brightness control in
    /// any useful sense — the surface is a measurement, so there is nothing to
    /// light harder; this only decides how hot the display is driven.
    var lift: Double = 0

    /// The shader's canvas, in cap heights — `kViewUnits` in `Wordmark.metal`,
    /// and it has to match. Wider and taller than the letters because the halo
    /// has to finish falling off inside it; cut to the letters, the glow would
    /// end at a straight edge.
    private static let canvasUnits = CGSize(width: 6.40, height: 2.40)

    /// What the letters themselves span. Exactly one cap height tall, since no
    /// terminal overshoots; the width is more than 4.38 because the italic
    /// leans the top of the word past its own right edge. This is the size the
    /// view *lays out* at, with the canvas overflowing it — so a caller spaces
    /// against the mark it can see rather than against a box of mostly halo,
    /// and the glow is free to bleed over whatever is next to it.
    private static let markUnits = CGSize(width: 4.64, height: 1.00)

    /// The frame held when the animation is off. Late enough in the pulse to
    /// be at full glow: a still of the mark at its dimmest is a worse still.
    private static let heldFrame: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `TimelineView(.animation)` for the same reason `SpinningPlasmaOrb` uses
    /// it — the motion is continuous and unbounded, so there's no keyframe pair
    /// to animate between, just elapsed time.
    ///
    /// Measured from here rather than the reference date for the precision
    /// reason spelled out in `DiscoHouse`: that's ~7.7e8, and the `float` the
    /// shader receives carries about seven significant digits, so the
    /// fractional part would quantise to steps coarser than a frame.
    @State private var start = Date()

    var body: some View {
        let canvas = CGSize(width: size * Self.canvasUnits.width,
                            height: size * Self.canvasUnits.height)

        Group {
            if reduceMotion || PowerState.shared.isLowPower {
                // No `TimelineView` at all rather than a frozen one: this is a
                // raymarch, and there's no reason to pay for it every frame to
                // redraw the same slab.
                //
                // Low Power Mode is consulted here and deliberately isn't by
                // the toolbar ornaments, which keep moving. The line isn't how
                // important a thing is, it's what it costs — those are cheap
                // enough that stopping them would buy nothing, and this one
                // marches a signed-distance field per pixel on a screen that
                // is already running the ripple field underneath it.
                mark(canvas: canvas, time: Self.heldFrame)
            } else {
                TimelineView(.animation) { timeline in
                    mark(canvas: canvas, time: timeline.date.timeIntervalSince(start))
                }
            }
        }
        // Lays out at the letters and draws past it. SwiftUI doesn't clip to a
        // frame, so the halo survives being sized out of its own box.
        .frame(width: size * Self.markUnits.width, height: size * Self.markUnits.height)
        .accessibilityElement()
        .accessibilityLabel("Addit")
    }

    private func mark(canvas: CGSize, time: Double) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: canvas.width, height: canvas.height)
            .colorEffect(
                ShaderLibrary.wordmark(
                    .float2(canvas.width, canvas.height),
                    .float(time),
                    .float(lift)
                )
            )
    }
}

/// The mark's own rake, as a shape: a rounded parallelogram leaning at exactly
/// the angle the letters do, for whatever the mark is standing on.
///
/// Lives here rather than with the screen that uses it because the number is
/// the wordmark's, not the plaque's. `slant` is x per unit of *height* and has
/// to match `kSlant` in `Wordmark.metal` — two copies of one value, for the
/// same reason `AdditWordmark.canvasUnits` duplicates `kViewUnits`: a shader
/// constant can't be read from Swift, and a plinth raked to a different angle
/// from the letters on it is worse than one that isn't raked at all.
struct SlantedPlaque: Shape {
    /// About 15°. `kSlant` in `Wordmark.metal`.
    var slant: CGFloat = 0.26
    var cornerRadius: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        // Inset by the lean and shear the result, so the parallelogram's
        // corners land *on* the corners of `rect` instead of outside it.
        //
        // That inset is what keeps the padding even. The mark's own layout box
        // already contains its lean — `markUnits` is 4.64 cap heights for a
        // word 4.38 wide — so a plaque sheared inside the same box sits the
        // same distance from the letters at every height. Sheared *around* the
        // box instead, it would crowd the T's arm and open a gap under the A.
        let lean = slant * rect.height
        let body = CGRect(x: rect.minX + lean / 2, y: rect.minY,
                          width: max(0, rect.width - lean), height: rect.height)
        let upright = Path(roundedRect: body, cornerRadius: cornerRadius,
                           style: .continuous)

        // Negated, and pivoted on the middle: SwiftUI's y runs down where the
        // shader's runs up, so what the mark does at its cap line this has to
        // do at its top edge. x' = x + slant · (midY − y).
        return upright.applying(CGAffineTransform(a: 1, b: 0, c: -slant, d: 1,
                                                  tx: slant * rect.midY, ty: 0))
    }
}

#Preview {
    VStack(spacing: 40) {
        AdditWordmark(size: 46, lift: 0.30)
        AdditWordmark()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.006, green: 0.004, blue: 0.021))
}
