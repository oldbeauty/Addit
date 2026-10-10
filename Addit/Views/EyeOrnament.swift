import SwiftUI

/// The tracking button's eyeball: turns with the library's scroll, as the orb
/// does, and tips and widens its pupil in the direction you flick.
///
/// Shape and colour are `Eyeball.metal`'s; this view only decides how far to
/// turn. Orientation follows scroll position and the tip follows scroll
/// velocity, through `ScrollTorque` — the split, and why, is written up there.
struct EyeOrnament: View {
    /// The library's content offset, in its box so the read happens here and
    /// not in `LibraryView` (see `ScrollOffsetBox`).
    var offset: ScrollOffsetBox
    var diameter: CGFloat = 26

    /// A third of the orb's rate (2026-10-07): an eye turning at the orb's
    /// speed spun too fast to read as one. A full turn is about seven screens.
    private static let radiansPerPoint: Double = 0.011 / 3
    /// Past this the eye tips far enough to show mostly its top or bottom.
    private static let maxTwist: Double = 1.0

    var body: some View {
        // From the top of the content, not from the raw offset, which sits at
        // minus the top inset there: the eye has a home position, the orb
        // doesn't. Twist comes from the change, so it reads either.
        let scrolled = offset.scrolled
        return ScrollTorque(scrollOffset: scrolled, maxTwist: Self.maxTwist) { twist in
            EyeballGlass(diameter: diameter, angle: scrolled * Self.radiansPerPoint, twist: twist)
        }
        .frame(width: diameter, height: diameter)
        // Drawn size, no padding: the toolbar sizes its glass around the
        // label, as `PlasmaOrb` explains.
        .contentShape(Rectangle())
    }
}

/// The eye at an explicit turn and tip, with nothing driving it.
struct EyeballGlass: View {
    var diameter: CGFloat
    /// Turn about the vertical, in radians; 0 looks (nearly) at you.
    var angle: Double
    /// Tip and pupil dilation, from `ScrollTorque`.
    var twist: Double

    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: diameter, height: diameter)
            .colorEffect(
                ShaderLibrary.eyeball(
                    .float2(diameter, diameter),
                    .float(angle),
                    .float(twist)
                )
            )
            .accessibilityHidden(true)
    }
}
