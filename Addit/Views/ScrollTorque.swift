import SwiftUI

/// Wraps a piece of scroll-driven glass and hands it the current *twist*.
///
/// Everything the library toolbar spins off the scroll splits into two
/// quantities, and they are different on purpose. Orientation follows scroll
/// **position**, so it tracks your thumb exactly and coasts to a stop with the
/// scroll view's own deceleration — each ornament works that out for itself
/// from the offset, since there is no state in it. Twist follows scroll
/// **velocity**, so it peaks mid-flick and unwinds to nothing when the list
/// settles — that needs a clock and a little state, and that is what lives
/// here so the orb and the marks cannot drift out of step with each other.
struct ScrollTorque<Content: View>: View {
    /// Content offset of whatever scroll view this is watching. Absolute, not
    /// a delta — none of the ornaments have a home position, so any value is
    /// valid.
    var scrollOffset: CGFloat
    /// Ceiling on the shear, in radians per world unit of height. Past its own
    /// ceiling each shape stops being itself: the orb's folds start passing
    /// through each other, and a brand mark stops being readable, which is why
    /// the marks ask for much less of it than the orb does.
    var maxTwist: Double
    @ViewBuilder var content: (Double) -> Content

    /// The scroll speed, in points/sec, that counts as "a good flick" — it
    /// lands around 70% of the twist ceiling, leaving headroom above.
    private static var briskScroll: Double { 1650 }
    /// How fast the twist unwinds once the scrolling stops, in seconds.
    private static var unwind: Double { 0.22 }

    /// Velocity as of the last scroll event, plus when that event happened.
    /// Between events the twist is a closed-form decay off this — there is no
    /// per-frame integration to drift or to keep alive.
    @State private var velocity: Double = 0
    @State private var stamp = Date.distantPast
    /// Bumped per scroll event purely to restart the settle timer below.
    @State private var event = 0
    /// False once the twist has decayed past visibility, which parks the
    /// timeline. A toolbar ornament has no business holding the display link
    /// open while the user reads a track list.
    @State private var isUnwinding = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isUnwinding)) { timeline in
            content(twist(at: timeline.date))
        }
        .onChange(of: scrollOffset) { old, new in
            absorb(delta: new - old)
        }
        // Restarts on every scroll event, so it only fires once the events have
        // actually stopped — at which point the twist is spent and the
        // timeline can park.
        .task(id: event) {
            guard isUnwinding else { return }
            try? await Task.sleep(for: .seconds(Self.unwind * 5))
            guard !Task.isCancelled else { return }
            velocity = 0
            isUnwinding = false
        }
    }

    /// Twist decays exponentially from whatever the last event measured. During
    /// a scroll the events arrive every frame so this is essentially live; once
    /// they stop it becomes the unwind.
    private func twist(at date: Date) -> Double {
        let age = date.timeIntervalSince(stamp)
        guard age.isFinite, age >= 0 else { return 0 }
        let decayed = velocity * exp(-age / Self.unwind)
        // tanh rather than a clamp: real flicks overshoot a plain limit by so
        // much that they'd all twist identically, and this keeps giving a
        // little more for a lot more speed instead of flattening off.
        return maxTwist * tanh(decayed / Self.briskScroll)
    }

    private func absorb(delta: CGFloat) {
        let now = Date()
        let gap = now.timeIntervalSince(stamp)
        // A gap this long is a new gesture, not a slow frame. Layout swaps
        // between the list and the grid also land here, and their offset jump
        // must not read as a thousand-point-per-frame flick.
        let isNewGesture = gap > 0.15
        let dt = min(max(gap, 1.0 / 120.0), 1.0 / 30.0)
        let instant = Double(delta) / dt

        let carried = isNewGesture ? 0 : velocity * exp(-gap / Self.unwind)
        // Smoothed, because per-frame offsets from a scroll view are jittery
        // enough to make an unsmoothed twist visibly buzz.
        velocity = carried + (instant - carried) * 0.35
        stamp = now
        event &+= 1
        if !isUnwinding { isUnwinding = true }
    }
}

extension View {
    /// Publish this scroll container's vertical content offset into `offset`.
    ///
    /// `onScrollGeometryChange` rather than a `GeometryReader` in the content:
    /// the reader only reports rows it is inside of, so it stops updating once
    /// its row is recycled out of a lazy grid, and it reports during layout
    /// rather than as the scroll moves.
    func tracksScrollOffset(into offset: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, new in
            offset.wrappedValue = new
        }
    }
}
