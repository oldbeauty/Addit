import SwiftUI

/// The sign-in screen's mark: a house turning on the spot with a party visible
/// through its windows. Shape, walls and lights all come from
/// `DiscoHouse.metal`; this view only supplies the clock.
///
/// `TimelineView(.animation)` for the same reason `SpinningPlasmaOrb` uses it —
/// the motion is continuous and unbounded, so there's no keyframe pair to
/// animate between.
struct DiscoHouse: View {
    var side: CGFloat = 120
    /// Seconds per revolution. Slow enough to read as an object being turned
    /// rather than a spinning icon; the lights supply the energy.
    var period: Double = 14

    /// Measured from here rather than the reference date: that's ~7.7e8 and
    /// `Float` carries about seven significant digits, so the fractional part
    /// would quantise to steps coarser than a frame and both the spin and the
    /// beat would stutter.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.discoHouse(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period),
                        .float(elapsed)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

#Preview {
    DiscoHouse(side: 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
}
