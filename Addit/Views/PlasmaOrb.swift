import SwiftUI

/// The library toolbar's bauble: one blob of glass that turns with the scroll
/// and wrings itself out in the direction you flick.
///
/// The shape and all of its colour come from `PlasmaOrb.metal` — this view only
/// decides how far to turn. The twist comes from `ScrollTorque`, which is also
/// where the reasoning about the two lives.
struct PlasmaOrb: View {
    /// Content offset of whatever scroll view this is watching.
    var scrollOffset: CGFloat
    var diameter: CGFloat = 28

    /// Radians of spin per point scrolled. A full turn is a bit over two
    /// screens: clearly tied to the gesture, slow enough not to smear. The orb
    /// is abstract, so unlike the brand marks it can just keep going round.
    private static let radiansPerPoint: Double = 0.011
    /// Past about this the folds start passing through each other and the
    /// silhouette goes to noise.
    private static let maxTwist: Double = 1.25

    var body: some View {
        ScrollTorque(scrollOffset: scrollOffset, maxTwist: Self.maxTwist) { twist in
            PlasmaOrbGlass(
                diameter: diameter,
                angle: scrollOffset * Self.radiansPerPoint,
                twist: twist
            )
        }
        .frame(width: diameter, height: diameter)
        // Left at the drawn size, with no tap-target padding of its own. The
        // toolbar sizes its glass around the label, so a label padded out to
        // 44pt comes back as an oval while the SF-symbol buttons beside it stay
        // circular. The chrome supplies the touch target anyway — it is the
        // capsule, not the label, that the finger has to hit.
        //
        // The shader paints most of this square transparent and SwiftUI
        // hit-tests the frame rather than the coverage, which is what we want:
        // the gaps between the blob's lobes stay live rather than punching
        // holes in the button.
        .contentShape(Rectangle())
    }
}

/// The blob at an explicit orientation and shear, with nothing driving it.
/// Both the toolbar's scroll-fed orb and the launch screen's freewheeling one
/// are this view with a different clock behind them — the shape and every bit
/// of its colour come from `PlasmaOrb.metal` either way.
struct PlasmaOrbGlass: View {
    var diameter: CGFloat
    /// Orientation in radians.
    var angle: Double
    /// Shear, in radians per world unit of height.
    var twist: Double

    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: diameter, height: diameter)
            .colorEffect(
                ShaderLibrary.plasmaOrb(
                    .float2(diameter, diameter),
                    .float(angle),
                    .float(twist)
                )
            )
    }
}

/// The orb turning under its own clock, for the one place with no scroll to
/// drive it: the launch screen.
///
/// `TimelineView(.animation)` for the same reason `RotatingStructureView` uses
/// it — the motion is continuous and unbounded, so there's no keyframe pair to
/// animate between, just elapsed time.
struct SpinningPlasmaOrb: View {
    var diameter: CGFloat = 64
    /// Seconds per revolution. Slow: this sits under a wordmark on a screen
    /// that's only up for a moment, and a fast spin reads as a busy-indicator
    /// rather than as an object.
    var period: Double = 7
    /// A standing shear, so it reads as glass being wrung rather than a ball
    /// rotating. Kept well under `PlasmaOrb`'s own ceiling, past which the
    /// folds start passing through each other.
    var twist: Double = 0.55

    /// Elapsed time is measured from here rather than the reference date, for
    /// the precision reason spelled out in `RotatingStructureView`.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            PlasmaOrbGlass(
                diameter: diameter,
                angle: 2 * .pi * timeline.date.timeIntervalSince(start) / period,
                twist: twist
            )
        }
        .frame(width: diameter, height: diameter)
    }
}

#Preview("Orb") {
    @Previewable @State var offset: CGFloat = 0

    VStack(spacing: 32) {
        PlasmaOrb(scrollOffset: offset, diameter: 160)
        HStack(spacing: 24) {
            PlasmaOrb(scrollOffset: offset, diameter: 28)
            PlasmaOrb(scrollOffset: offset + 40, diameter: 44)
        }
        Slider(value: $offset, in: -600...600)
    }
    .padding(40)
    .background(Color(red: 0.05, green: 0.05, blue: 0.06))
}
