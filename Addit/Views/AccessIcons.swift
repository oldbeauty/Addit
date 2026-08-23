import SwiftUI

/// The three raymarched ornaments on the Access sheet. Shapes and lighting all
/// live in `AccessIcons.metal`; these views only supply the clock.
///
/// Only the globe turns all the way round. The hazard plate and the chain rock
/// instead — the same rule the library's brand marks follow, and here it earns
/// its keep twice: a flat plate seen edge-on vanishes, and two rings square-on
/// collapse into a figure-of-eight.

/// "Anyone with the link" — a world, turning.
struct GlobeIcon: View {
    var side: CGFloat = 30
    /// Seconds per revolution. A real globe on a stand, not a loading spinner.
    var period: Double = 18

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.accessGlobe(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// "Restricted" — a moulded hazard plate.
struct HazardIcon: View {
    var side: CGFloat = 30
    /// Seconds per rock cycle.
    var period: Double = 9

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.accessHazard(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The album link itself — two chrome links.
struct ChainIcon: View {
    var side: CGFloat = 30
    var period: Double = 11

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.accessChain(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 28) {
        GlobeIcon(side: 96)
        HazardIcon(side: 96)
        ChainIcon(side: 96)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
}
