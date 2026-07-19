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
