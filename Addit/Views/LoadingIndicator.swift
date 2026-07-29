import SwiftUI

/// The app's one and only indeterminate "working on it" spinner. Every place
/// that used a bare `ProgressView()` uses this instead, so busy states read the
/// same everywhere.
///
/// This is **not** for determinate progress. Anything that knows how far along
/// it is — album downloads, cache fills, track-split analysis — keeps its own
/// bar or ring (`CacheProgressRing` in `AlbumDetailSupport.swift`, the capsule
/// bars in the download/import overlays). Those communicate a fraction; this
/// communicates only "still going".
///
/// The glyph is a port of `morphing-infinity` from turbostarter/loading-ui: a
/// single open stroke that cycles circle → infinity → circle → infinity → circle
/// over 5 seconds. The two circles wind in opposite directions, so the loop
/// never visibly rewinds.
struct LoadingIndicator: View {
    /// Optional caption under the glyph — the replacement for
    /// `ProgressView("Loading…")`.
    var label: String?
    var size: Size = .regular
    /// Stroke color. Defaults to the environment tint (the theme accent
    /// everywhere below `ContentView`).
    var tint: Color?

    enum Size {
        /// Inline with text or toolbar glyphs.
        case small
        /// Default — standalone in a row, cell, or overlay card.
        case regular
        /// Full-screen and splash states.
        case large

        var points: CGFloat {
            switch self {
            case .small: 20
            case .regular: 28
            case .large: 40
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one full circle → infinity → circle → infinity → circle
    /// cycle, from the original.
    private static let period: Double = 5

    var body: some View {
        VStack(spacing: 10) {
            glyph
            if let label {
                Text(label)
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Driven off the wall clock rather than a `withAnimation` + `@State` loop.
    /// These spinners get inserted inside fading overlays, sheets and list
    /// transitions, where a `repeatForever` animation kicked off in `onAppear`
    /// can be swallowed by the surrounding transaction and never start. Reading
    /// the time has no such failure mode, costs no state, and has the bonus
    /// that every spinner on screen stays in lockstep.
    private var glyph: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let cycle = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period

            MorphingInfinityShape(phase: reduceMotion ? 1 : cycle * 4)
                .stroke(
                    tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint),
                    style: StrokeStyle(
                        // 1.5 stroke units in the source's 24-unit viewBox,
                        // with a floor so the small size doesn't wash out.
                        lineWidth: max(1.1, size.points * (1.5 / 24)),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                // Reduce Motion holds the infinity still and breathes it
                // instead — the "something is happening" cue survives without
                // the morph.
                .opacity(reduceMotion ? 0.4 + 0.6 * (0.5 + 0.5 * cos(cycle * 4 * .pi)) : 1)
        }
        .frame(width: size.points, height: size.points)
    }
}

/// One closed stroke morphing through the `morphing-infinity` keyframes.
///
/// All three keyframe paths are `M` + four cubic curves, laid out so their
/// control points correspond one-to-one. That's what makes the morph a plain
/// per-point interpolation — the same thing the web original's path animation
/// does numerically.
private struct MorphingInfinityShape: Shape {
    /// Position in the loop, `0...4`, one unit per keyframe leg. Deliberately
    /// *not* exposed as `animatableData`: the timeline hands over the exact
    /// value for each frame already, and making it animatable would let an
    /// ambient animation on some ancestor interpolate toward it and drag the
    /// morph out of sync.
    var phase: Double

    /// 13 points per keyframe: the start point, then (control, control, end)
    /// for each of the four curves. Coordinates are in the source 24×24 box.
    private static let circleA: [CGPoint] = [
        CGPoint(x: 12, y: 8),
        CGPoint(x: 14.21, y: 8), CGPoint(x: 16, y: 9.79), CGPoint(x: 16, y: 12),
        CGPoint(x: 16, y: 14.21), CGPoint(x: 14.21, y: 16), CGPoint(x: 12, y: 16),
        CGPoint(x: 9.79, y: 16), CGPoint(x: 8, y: 14.21), CGPoint(x: 8, y: 12),
        CGPoint(x: 8, y: 9.79), CGPoint(x: 9.79, y: 8), CGPoint(x: 12, y: 8),
    ]

    private static let infinity: [CGPoint] = [
        CGPoint(x: 12, y: 12),
        CGPoint(x: 14, y: 8.5), CGPoint(x: 19, y: 8.5), CGPoint(x: 19, y: 12),
        CGPoint(x: 19, y: 15.5), CGPoint(x: 14, y: 15.5), CGPoint(x: 12, y: 12),
        CGPoint(x: 10, y: 8.5), CGPoint(x: 5, y: 8.5), CGPoint(x: 5, y: 12),
        CGPoint(x: 5, y: 15.5), CGPoint(x: 10, y: 15.5), CGPoint(x: 12, y: 12),
    ]

    /// Same circle as `circleA` but entered from the bottom and wound the other
    /// way, so returning through the infinity carries on rather than reversing.
    private static let circleB: [CGPoint] = [
        CGPoint(x: 12, y: 16),
        CGPoint(x: 14.21, y: 16), CGPoint(x: 16, y: 14.21), CGPoint(x: 16, y: 12),
        CGPoint(x: 16, y: 9.79), CGPoint(x: 14.21, y: 8), CGPoint(x: 12, y: 8),
        CGPoint(x: 9.79, y: 8), CGPoint(x: 8, y: 9.79), CGPoint(x: 8, y: 12),
        CGPoint(x: 8, y: 14.21), CGPoint(x: 9.79, y: 16), CGPoint(x: 12, y: 16),
    ]

    private static let keyframes = [circleA, infinity, circleB, infinity, circleA]

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(phase, 0), 4)
        let leg = min(Int(clamped), 3)
        // Smoothstep stands in for the original's per-keyframe easeInOut; the
        // two are visually indistinguishable at this scale.
        let raw = clamped - Double(leg)
        let t = raw * raw * (3 - 2 * raw)

        let from = Self.keyframes[leg]
        let to = Self.keyframes[leg + 1]

        // Fit the 24×24 source box into `rect`, centered.
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * scale
        let originY = rect.midY - 12 * scale

        func point(_ index: Int) -> CGPoint {
            let a = from[index], b = to[index]
            return CGPoint(
                x: originX + (a.x + (b.x - a.x) * t) * scale,
                y: originY + (a.y + (b.y - a.y) * t) * scale
            )
        }

        var path = Path()
        path.move(to: point(0))
        for curve in 0..<4 {
            let base = 1 + curve * 3
            path.addCurve(
                to: point(base + 2),
                control1: point(base),
                control2: point(base + 1)
            )
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 40) {
        LoadingIndicator(size: .small)
        LoadingIndicator(size: .regular)
        LoadingIndicator(label: "Loading…", size: .large)
    }
    .tint(.orange)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
}
