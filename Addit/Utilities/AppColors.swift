import SwiftUI
import UIKit

extension Color {
    /// App-wide window/background color. Light mode keeps the standard system
    /// background (white); dark mode uses a warm charcoal instead of iOS's
    /// pure-black `systemBackground`, so large dark surfaces read softer —
    /// closer to editor/terminal UIs than an OLED void.
    ///
    /// Tweak the dark value here (single source of truth). Everything else
    /// paints this via the `.appBackground()` modifier.
    static let appBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1) // #121212 (Spotify's base dark)
            : .systemBackground
    })
}

extension Color {
    /// Black or white, whichever stays legible on top of this color. Used so
    /// an icon over an accent-filled control never vanishes at the light/dark
    /// extremes of the accent palette.
    var legibleForeground: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }

    /// This color, darkened only as far as it takes for a **white** label to
    /// stay readable on top of it. Returns itself when it is already dark
    /// enough.
    ///
    /// For controls we draw ourselves, `legibleForeground` is the better tool —
    /// it keeps the accent exact and flips the text instead. This exists for
    /// system-drawn chrome where the label color isn't ours to set: a
    /// `.swipeActions` button template-renders its icon and title white — in
    /// *both* schemes, verified on iOS 26 — and ignores `foregroundStyle`, a
    /// `colorScheme` override, and per-component styling inside the `Label`
    /// alike. The tint is the only lever left, so a pale accent from the
    /// palette (`F1E9DB`, `FFFFFF`) has to give way here or the glyph vanishes
    /// into its own pill. Note this is not a dark-mode-only problem even though
    /// that's where it shows up: accents are stored per scheme, so it surfaces
    /// in whichever scheme the pale color was picked for.
    ///
    /// The one escape hatch, if you ever want the accent shown at its exact
    /// value: a `UIImage` carrying `.alwaysOriginal` keeps its own color, but
    /// *only* as the button's entire label. Give it a `Label` with title text
    /// alongside and the white template pass comes back for both.
    ///
    /// Scaling every channel by one factor is exactly a reduction in HSB
    /// brightness: hue and saturation come through untouched, so the pill still
    /// reads as the user's accent, just deeper.
    var legibleUnderWhiteLabel: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        // Sits under `legibleForeground`'s 0.6 flip point with a little margin,
        // so the two helpers can never disagree about the same color.
        let ceiling: CGFloat = 0.55
        guard luminance > ceiling else { return self }
        let factor = ceiling / luminance
        return Color(red: r * factor, green: g * factor, blue: b * factor, opacity: a)
    }

    /// This color, moved just far enough to read *against* `Color.appBackground`
    /// in the given scheme, and returned untouched when it already does.
    ///
    /// The two helpers above protect a label drawn **on top of** this color.
    /// This one is for color used as ink — waveform bars, marks on the window
    /// background — where the same color has to survive both a near-black
    /// (`#121212`) and a white backdrop. A cover accent can't be trusted to do
    /// that on its own: a pale yellow sleeve is invisible in light mode, a deep
    /// navy one invisible in dark.
    ///
    /// The two directions are not the same operation:
    ///
    /// - **Darkening** is one scale factor across all three channels, which is
    ///   exactly a drop in HSB brightness — hue and saturation come through
    ///   untouched.
    /// - **Brightening** can't be. Scaling up clips whichever channel is
    ///   already highest and drags the hue with it, so this blends toward white
    ///   instead: hue survives, and the light is paid for in saturation. That's
    ///   the right trade for a color that only has to stay recognisable as the
    ///   cover's, not stay exact.
    ///
    /// Both branches land on their target luminance exactly. Luminance is a
    /// linear combination of the channels whose weights sum to 1, so scaling
    /// every channel by `k` scales luminance by `k`, and blending every channel
    /// toward 1 by `t` moves luminance to `lum + (1 - lum)·t`.
    func legibleOnAppBackground(_ scheme: ColorScheme) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        if scheme == .dark {
            let floor: CGFloat = 0.42
            guard luminance < floor else { return self }
            let t = (floor - luminance) / max(0.0001, 1 - luminance)
            return Color(
                red: r + (1 - r) * t,
                green: g + (1 - g) * t,
                blue: b + (1 - b) * t,
                opacity: a
            )
        } else {
            // Same ceiling as `legibleUnderWhiteLabel`, for the same reason:
            // one flip point for the whole file.
            let ceiling: CGFloat = 0.55
            guard luminance > ceiling else { return self }
            let factor = ceiling / luminance
            return Color(red: r * factor, green: g * factor, blue: b * factor, opacity: a)
        }
    }

    /// The page, taken over by this colour — the record's own hue, run as hard
    /// as a page you still have to read can carry it.
    ///
    /// Deliberately **not** a blend toward the accent, which is the obvious
    /// implementation and the one that doesn't work. Mixing a vibrant swatch
    /// into the base at a fixed fraction lands somewhere different for every
    /// cover: a neon yellow lifts the page well clear of the base, a near-black
    /// navy barely moves it at all, and the same screen reads as a different
    /// brightness album to album. What carries over from the accent is only its
    /// **hue**, taken to full saturation; every album then tints the page by
    /// the same amount and only the direction changes.
    ///
    /// The knob that holds that invariant is **luminance, not HSB brightness**,
    /// and the difference only bites once the effect is strong. HSB brightness
    /// is the largest channel, which is not what the eye reads: at brightness
    /// 0.3 a yellow is `(0.3, 0.3, 0)` and a blue is `(0, 0, 0.3)`, and the
    /// yellow is roughly seven times the luminance. Faint, nobody could tell.
    /// At this strength that same pair is a bright olive page and a nearly
    /// black one, which is exactly the album-to-album lurch the hue-only rule
    /// exists to prevent. So the two constants below are luminances, each hue
    /// is driven onto its target, and what varies between them is saturation —
    /// yellow arrives deep and fully saturated, blue arrives lightened,
    /// because that is what those hues cost to reach one common weight.
    ///
    /// Those two constants are the whole intensity control, and they are set
    /// at the legibility ceiling rather than at the maximum: dark has to keep
    /// white and `.secondary` labels off it, light has to keep black ones. Turn
    /// them toward the base (0.07 dark, 1 light) to calm the page down; there
    /// is not much room left in the other direction.
    ///
    /// Returns the plain background for a colour with no hue worth taking —
    /// the caller gets the untinted page rather than a grey cast.
    /// Target luminance for a tinted page in dark mode. The base charcoal is
    /// 0.07, so this is a little over double it — a page that is plainly the
    /// record's colour, with white body copy still well clear of it.
    private var darkTintLuminance: CGFloat { 0.17 }

    /// Target luminance for a tinted page in light mode, down from white's 1.
    /// Lower than this and black labels start working for their contrast on
    /// the hues that have to arrive saturated to reach it.
    private var lightTintLuminance: CGFloat { 0.80 }

    func asAppBackgroundTint(_ scheme: ColorScheme) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a),
              s > 0.05
        else { return .appBackground }

        // The hue at its fullest: the most colour there is to be had in this
        // direction, before the luminance pin takes back whatever it must.
        var r: CGFloat = 0, g: CGFloat = 0, blue: CGFloat = 0
        UIColor(hue: h, saturation: 1, brightness: 1, alpha: 1)
            .getRed(&r, green: &g, blue: &blue, alpha: &a)

        let target = scheme == .dark ? darkTintLuminance : lightTintLuminance
        let luminance = 0.299 * r + 0.587 * g + 0.114 * blue

        // The same two moves, and the same asymmetry, as
        // `legibleOnAppBackground`: scaling down is a pure drop in HSB
        // brightness and costs nothing, while lifting has to blend toward
        // white and is paid for in saturation. Every hue lands on `target`
        // exactly — scaling all three channels by `k` scales luminance by `k`,
        // and blending them toward 1 by `t` moves it to `lum + (1 - lum)·t`.
        if luminance > target {
            let k = target / luminance
            return Color(red: r * k, green: g * k, blue: blue * k)
        } else {
            let t = (target - luminance) / max(0.0001, 1 - luminance)
            return Color(
                red: r + (1 - r) * t,
                green: g + (1 - g) * t,
                blue: blue + (1 - blue) * t
            )
        }
    }
}

extension View {
    /// Paint `Color.appBackground` behind a scrollable surface, hiding the
    /// scroll view / List's own opaque background so the charcoal shows
    /// through. Apply to each screen's root scrollable container.
    /// Pass a `tint` (see `asAppBackgroundTint`) to have the page take on the
    /// current artwork's hue instead of the flat base. It crossfades, because
    /// the value arrives when the cover resolves — which on a cold album is
    /// after the page is already on screen, and a hard cut there reads as a
    /// glitch rather than as the art landing.
    func appBackground(tint: Color? = nil) -> some View {
        appBackground(tint: tint, fadingOver: nil)
    }

    /// As above, but the tint dissolves into the plain background across
    /// `fadingOver` — a top-down span given in fractions of the screen's
    /// height. Album detail hands it the cover's own top and bottom edges, so
    /// the wash is at full strength where the art begins and gone by where it
    /// ends.
    ///
    /// The tint is painted as a *mask* over the ordinary background rather than
    /// as a two-colour gradient, for two reasons. Interpolating between two
    /// `Color`s means unpacking them to components, and — more importantly — a
    /// straight ramp has a corner where it leaves the flat region, which the eye
    /// picks up as a band even when the colours are close. Alpha stops are easy
    /// to shape, so the ramp follows a smoothstep and starts and ends on a
    /// tangent instead of a corner.
    func appBackground(tint: Color?, fadingOver span: ClosedRange<CGFloat>?) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background {
                Group {
                    if let tint, let span, span.upperBound > span.lowerBound {
                        Color.appBackground.overlay {
                            tint.mask(
                                LinearGradient(
                                    stops: appWashStops(from: span.lowerBound,
                                                        to: span.upperBound),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                    } else {
                        tint ?? .appBackground
                    }
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: tint)
            }
    }


    /// Replace iOS 26's adaptive top scroll edge effect with a static fade.
    /// The system effect samples the content scrolling under the top bar and
    /// flips between light and dark treatments on its own — the status-bar
    /// clock/wifi text flips with it — regardless of the app's scheme. This
    /// hides it, draws a fixed `Color.appBackground` fade (white in light,
    /// charcoal in dark), and pins the bar scheme so nothing up there reacts
    /// to what scrolls underneath. Apply to a screen's root scrollable
    /// container, alongside `.appBackground()`.
    ///
    /// Takes the same `tint` as `appBackground(tint:)` and must be given it
    /// whenever that one is: this fade *is* the background, continued up over
    /// the bar, and a tinted page under an untinted fade shows the join.
    func staticTopFade(tint: Color? = nil) -> some View {
        modifier(StaticTopFadeModifier(tint: tint))
    }
}

private struct StaticTopFadeModifier: ViewModifier {
    var tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let base = tint ?? .appBackground
        return content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: base, location: 0),
                            .init(color: base.opacity(0.85), location: 0.4),
                            .init(color: base.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 110)
                    .animation(.easeInOut(duration: 0.5), value: tint)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

/// Alpha stops tracing `1 - smoothstep` across the span. The interior
/// values are the curve sampled at quarters; the flat runs either side are
/// what make the start and end of the fade impossible to locate.
private func appWashStops(from start: CGFloat, to end: CGFloat) -> [Gradient.Stop] {
    let span = end - start
    let curve: [(CGFloat, Double)] = [
        (0.00, 1.000),
        (0.25, 0.844),
        (0.50, 0.500),
        (0.75, 0.156),
        (1.00, 0.000),
    ]
    var stops: [Gradient.Stop] = [.init(color: .white, location: 0)]
    stops += curve.map { .init(color: .white.opacity($0.1), location: start + span * $0.0) }
    stops.append(.init(color: .clear, location: 1))
    return stops
}
