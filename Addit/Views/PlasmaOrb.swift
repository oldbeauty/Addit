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
            Rectangle()
                .fill(.white)
                .frame(width: diameter, height: diameter)
                .colorEffect(
                    ShaderLibrary.plasmaOrb(
                        .float2(diameter, diameter),
                        .float(scrollOffset * Self.radiansPerPoint),
                        .float(twist)
                    )
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
