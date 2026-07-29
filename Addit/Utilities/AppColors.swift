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
}

extension View {
    /// Paint `Color.appBackground` behind a scrollable surface, hiding the
    /// scroll view / List's own opaque background so the charcoal shows
    /// through. Apply to each screen's root scrollable container.
    func appBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
    }

    /// Replace iOS 26's adaptive top scroll edge effect with a static fade.
    /// The system effect samples the content scrolling under the top bar and
    /// flips between light and dark treatments on its own — the status-bar
    /// clock/wifi text flips with it — regardless of the app's scheme. This
    /// hides it, draws a fixed `Color.appBackground` fade (white in light,
    /// charcoal in dark), and pins the bar scheme so nothing up there reacts
    /// to what scrolls underneath. Apply to a screen's root scrollable
    /// container, alongside `.appBackground()`.
    func staticTopFade() -> some View {
        modifier(StaticTopFadeModifier())
    }
}

private struct StaticTopFadeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .appBackground, location: 0),
                            .init(color: .appBackground.opacity(0.85), location: 0.4),
                            .init(color: .appBackground.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 110)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}
