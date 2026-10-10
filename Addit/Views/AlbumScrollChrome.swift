import SwiftUI

// What the album page's bar picks up from the scroll: once the header's own
// shuffle and play have gone under the bar, a thumbnail of the cover appears
// in it, on glass, that takes you back to the top where they are.
//
// The arrival has to be free, because it happens mid-scroll, and twice it
// wasn't (the album's title in the bar, months ago, and this cover at first):
// a small but visible lag on the frame it came in. Two costs, both avoided by
// construction here:
//
// - The page rebuilding. The flag was `@State` on `AlbumDetailView`, so
//   flipping it re-ran that view's body — the whole List and every track row,
//   and the toolbar — in the middle of a scroll. It lives in `AlbumChrome`
//   now, which only `AlbumTopButton` reads.
// - The bar reconfiguring. Adding or removing a toolbar item makes UIKit lay
//   the navigation bar out again, which the folder zoom measured at the better
//   part of 120 ms (`skill://library-screen`). The item is always there, at a
//   fixed size; what appears is its content.
//
// Plus a small one: the cover is a thumbnail at the size drawn, loaded with
// the page rather than on the frame it appears.
//
// And one that was left after those, on the first arrival only: at opacity 0
// a layer isn't drawn at all, so the glass's backdrop and the thumbnail's
// texture were set up on the frame it first appeared, mid-scroll. It's drawn
// — barely — from just after the page settles instead, the way the folder
// zoom keeps its panel "a hundredth above zero" (`skill://library-screen`), so
// that first draw happens while nothing is moving.
//
// Tried and taken out on 2026-10-09: folding the header away as the page
// scrolled (a List row changing height every frame was choppy), and copies of
// shuffle and play in the bar.

/// The scroll as the bar needs it. An object so that its readers, and only
/// they, invalidate when it changes — not the page that owns it.
@Observable
final class AlbumChrome {
    /// The header's play and shuffle are under the bar.
    var headerIsPast = false

    /// The test, run in `onScrollGeometryChange`'s transform. `buttonsBottom`
    /// is the title line's bottom edge in the content's own coordinates, from
    /// its top under the bar; 0 means not measured yet.
    nonisolated static func headerIsPast(_ geometry: ScrollGeometry, buttonsBottom: CGFloat) -> Bool {
        let scrolled = geometry.contentOffset.y + geometry.contentInsets.top
        return buttonsBottom > 0 && scrolled > buttonsBottom
    }
}

/// The cover in the bar, on its own glass (a principal item gets none — the
/// library's centre menu is drawn the same way), scrolling the page back to
/// the top. Always in the bar at its full size, hidden until the header's
/// controls are past; see the top of this file for why.
struct AlbumTopButton: View {
    let chrome: AlbumChrome
    let album: Album
    let action: () -> Void

    private static let coverSize: CGFloat = 30
    private static let padding: CGFloat = 7
    /// Hidden but drawn: far too faint to see, enough that Core Animation
    /// renders it, which is what sets up its glass and its texture.
    private static let primedOpacity = 0.011
    /// When to draw it the first time: after the push that brought the page
    /// in has finished moving.
    private static let primeDelay: Duration = .milliseconds(600)

    /// Drawn (at `primedOpacity`) while hidden — from shortly after it
    /// appears, so its first draw doesn't land on the push either.
    @State private var isPrimed = false

    var body: some View {
        let shown = chrome.headerIsPast
        Button(action: action) {
            AlbumArtworkThumbnail(album: album, size: Self.coverSize, cornerRadius: 5)
                .padding(Self.padding)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : (isPrimed ? Self.primedOpacity : 0))
        // The same footprint shown or not, so nothing about the bar's layout
        // changes when it appears.
        .frame(width: Self.coverSize + 2 * Self.padding, height: Self.coverSize + 2 * Self.padding)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel("Back to the top of \(album.name)")
        .task {
            try? await Task.sleep(for: Self.primeDelay)
            isPrimed = true
        }
    }
}
