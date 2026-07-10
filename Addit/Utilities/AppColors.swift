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
}
