import SwiftUI

// MARK: - The line

/// Where the library grid's labels are: on the rows that have scrolled up to a
/// line, and nowhere below it.
///
/// The line is where the last of the rows labelled at rest
/// (`labelledAtRest`) has its labels when the library opens. A row below it
/// is bare — cover to cover, a gutter apart, as tight as Cosmos packs them —
/// and as it scrolls up to the line its label fades in and the gap under it
/// opens to make room; scrolled back down, the gap closes over it again. All
/// of it is a function of the scroll position and none of it is timed, so the
/// label follows the finger both ways, at any speed.
///
/// One definition, read twice: the cards draw from it (through
/// `LibraryLabelReveal`) and `LibraryGridGeometry` places slots with it, so
/// what's on screen and what a drag lands on can't disagree.
struct LibraryLabelLine: Equatable {
    var cover: CGFloat
    var gap: CGFloat

    /// The rows labelled when the library opens: the top two. The line is
    /// where the last of them has its labels, so this is also how many rows
    /// stay labelled below the toolbar as the grid scrolls.
    static let labelledAtRest = 2

    /// Cover top to cover top, with the label hidden.
    var barePitch: CGFloat { cover + gap }
    /// …and with it shown. Row `n` is at the line once the grid has scrolled
    /// `n − labelledAtRest + 1` of these from rest, every row above it labelled
    /// by then.
    var labelledPitch: CGFloat { barePitch + AlbumCard.labelBlock }

    /// The rows labelled at rest, from the grid's top to the line: what
    /// `LibraryView.gridRunway` leaves room after the last row to match.
    var restingSpan: CGFloat {
        let rows = CGFloat(Self.labelledAtRest)
        return rows * (cover + AlbumCard.labelBlock) + (rows - 1) * gap
    }

    /// How far a row travels while its label comes in, finishing at the line.
    ///
    /// Bounded both ways. Under `barePitch`, so only one row is ever part-way,
    /// which `rowTop` relies on. And well over the label's height: the gap
    /// opening pushes every row below it down, so those rows rise at
    /// (1 − label × slope) of the finger's pace, where the ease's slope peaks
    /// at 1.5 / `travel`. A short travel stalls them under the finger; under
    /// 1.5 labels it runs them backwards.
    var travel: CGFloat { barePitch * 0.6 }

    /// How far in row `row`'s label is, 0…1, with the grid scrolled `scrolled`
    /// from rest. The rows labelled at rest always are, and pulling down past
    /// the top (`scrolled` < 0) changes nothing.
    func progress(row: Int, scrolled: CGFloat) -> CGFloat {
        // The scroll at which `row` reaches the line.
        let arrival = CGFloat(row - Self.labelledAtRest + 1) * labelledPitch
        let t = (max(scrolled, 0) - arrival) / travel + 1
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// The first row whose label isn't all the way in: the one at the line.
    /// Every row above it is labelled, every row below it bare.
    func edgeRow(scrolled: CGFloat) -> Int {
        Int(max(scrolled, 0) / max(labelledPitch, 1)) + Self.labelledAtRest
    }

    /// Where row `row`'s covers start, below the grid's top edge.
    func rowTop(_ row: Int, scrolled: CGFloat) -> CGFloat {
        let edge = edgeRow(scrolled: scrolled)
        // The labels above a row: every one above the edge, and past the edge
        // only the edge row's share — the rows between it and this one are bare.
        let labelsAbove = row <= edge
            ? CGFloat(row)
            : CGFloat(edge) + progress(row: edge, scrolled: scrolled)
        return CGFloat(row) * barePitch + AlbumCard.labelBlock * labelsAbove
    }
}

// MARK: - What the cards read

/// The library grid's labels as its cards read them: which row is at the line,
/// and how far in that row's label is.
///
/// Two numbers rather than the scroll offset, so a card depends on only what
/// it draws. Every card reads `edgeRow`, which changes once a row; only the
/// cards in that row go on to read `edgeProgress`, which changes every frame.
/// A scroll frame invalidates the two cards whose label is moving rather than
/// a screenful — `ScrollOffsetBox` has the story of what a scroll-driven
/// dependency in the wrong place costs.
@Observable
final class LibraryLabelReveal {
    /// At rest until `place()` says otherwise, so a grid's first frame already
    /// has the rows labelled at rest labelled.
    private(set) var edgeRow = LibraryLabelLine.labelledAtRest
    private(set) var edgeProgress: CGFloat = 0

    @ObservationIgnored private(set) var scrolled: CGFloat = 0
    @ObservationIgnored var line = LibraryLabelLine(cover: 150, gap: 12) {
        didSet { place() }
    }

    /// How far in row `row`'s label is, 0…1.
    func progress(ofRow row: Int) -> CGFloat {
        if row < edgeRow { return 1 }
        if row > edgeRow { return 0 }
        return edgeProgress
    }

    func scroll(to scrolled: CGFloat) {
        self.scrolled = scrolled
        place()
    }

    private func place() {
        let edge = line.edgeRow(scrolled: scrolled)
        edgeRow = edge
        edgeProgress = line.progress(row: edge, scrolled: scrolled)
    }
}

/// A card's title block, in the library grid: all there above the line, and
/// coming out of nothing as the card's row scrolls up to it — the gap under
/// the cover widening to take it, the words fading up into it. With no row, or
/// anywhere but the library's grid (an open folder's), simply there.
struct LibraryCardLabel<Content: View>: View {
    let row: Int?
    @ViewBuilder let content: Content

    @Environment(LibraryLabelReveal.self) private var reveal: LibraryLabelReveal?

    var body: some View {
        let shown = row.flatMap { reveal?.progress(ofRow: $0) } ?? 1
        content
            .padding(.top, AlbumCard.labelSpacing)
            .frame(height: AlbumCard.labelBlock * shown, alignment: .top)
            .clipped()
            // Clipping hides the part of the label that doesn't fit yet, but
            // doesn't stop it catching touches: without this, a hidden label
            // still hangs a card's tap target into the gap below its cover.
            .contentShape(Rectangle())
            // Squared, so the words follow the room made for them rather than
            // arriving with it: half open, the title is a quarter there.
            .opacity(shown * shown)
    }
}

// MARK: - Driving it

extension View {
    /// Label this scroll view's library grid by `line`: owns the
    /// `LibraryLabelReveal` the cards inside read, and moves it with the
    /// scroll. `onScroll` hears the same position, for arithmetic that has to
    /// agree with what the cards draw (`LibraryGridGeometry.scrolled`).
    func revealsLibraryLabels(
        _ line: LibraryLabelLine,
        onScroll: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(LibraryLabelRevealHost(line: line, onScroll: onScroll))
    }
}

/// Holds the reveal for exactly as long as the scroll view it measures. A grid
/// built fresh — a library switch, the list toggled back to the grid — starts
/// at rest, and so does a reveal built with it; one kept by the library would
/// carry the last grid's scroll into the new one.
private struct LibraryLabelRevealHost: ViewModifier {
    let line: LibraryLabelLine
    let onScroll: (CGFloat) -> Void

    @State private var reveal = LibraryLabelReveal()

    func body(content: Content) -> some View {
        content
            .environment(reveal)
            // Measured from rest. At rest `contentOffset` is minus the bars'
            // height, not zero, and the line is defined by where the grid rests.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, scrolled in
                reveal.scroll(to: scrolled)
                onScroll(scrolled)
            }
            .onChange(of: line, initial: true) {
                reveal.line = line
                onScroll(reveal.scrolled)
            }
    }
}
