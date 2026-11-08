import SwiftUI
import UIKit

// MARK: - The labels

/// Where the library grid's labels are — which depends on the way the grid was
/// last scrolled, not just how far.
///
/// The grid opens with its top rows named (`labelledAtRest`). Scrolling down
/// takes labels away and scrolling up gives them back, a row at a time, in a
/// run over the rows on screen (`LibraryLabelState`) — from the bottom up,
/// whichever way: each row's label gone, or back, before the one above it
/// starts. A label going closes its gap and pulls the rows under it up; one
/// coming back opens it and pushes them down. Only the rows on screen as the
/// scroll turns take turns: rows scrolled on while hiding come on bare, so
/// the grid goes on cover to cover, a gutter apart — as tight as Cosmos packs
/// them — for as long as it's scrolled down, and rows scrolled on while
/// revealing come on already named, with nothing to watch. Each step happens
/// over a stretch of the scroll rather than on a clock (`stepTravel`), so it
/// follows the finger, at any speed.
///
/// Three rules keep that from ever showing a seam.
///
/// **Nothing seen snaps.** A label changes a frame's worth at a time, never
/// all at once — under the bars too, which show what's under them (taking
/// labels back there at once read as titles snapping away, 2026-10-20). A run
/// is the rows whose labels show below the bars; the rows above it, under the
/// bars and off the top, keep what they have while hiding.
///
/// **A row the grid hasn't laid out never changes.** A lazy grid places what's
/// on screen by the heights it last measured: change a row above the screen and
/// the screen is placed by its old height, then jumps when the grid finds out
/// (hundreds of points, in a probe, 2026-10-20). So a row of the run going off
/// the top keeps the label it was last laid out with (`settleExits`).
///
/// **Rows above the run come down named.** Revealing, each row above the run
/// that the grid has laid out grows its label as the scroll goes, a step's
/// worth (`growAbove`), with the scroll view moved by however much it grew in
/// the same frame, so nothing below it moves on screen (checked frame by frame
/// in a recording). A row coming on at the top edge is named before it's out
/// from under the bars; one under them as the scroll turns fills in there.
/// That's the illusion: they never open where you can see, and nothing below
/// them knows they did.
///
/// One definition, read twice: the cards draw from it (through
/// `LibraryLabelReveal`) and `LibraryGridGeometry` places slots with it, so
/// what's on screen and what a drag lands on can't disagree.
struct LibraryLabelLine: Equatable {
    var cover: CGFloat
    var gap: CGFloat

    /// The rows labelled when the library opens: the top two, the first run,
    /// done.
    static let labelledAtRest = 2

    /// Cover top to cover top, with the label hidden.
    var barePitch: CGFloat { cover + gap }

    /// The rows labelled at rest, from the grid's top to the bottom of the
    /// last one's label: what `LibraryView.gridRunway` leaves room after the
    /// last row to match.
    var restingSpan: CGFloat {
        let rows = CGFloat(Self.labelledAtRest)
        return rows * (cover + AlbumCard.labelBlock) + (rows - 1) * gap
    }

    /// How far the grid scrolls while one row of a run gets its label, or
    /// loses it; a screenful's run of five takes a row and three-quarters. A
    /// label coming or going moves every row below it, the way the grid is
    /// already going, so those rows run ahead of the finger by label × slope,
    /// where the ease's slope peaks at 1.5 / this. Shorter and they lurch;
    /// longer and a run is still going rows later.
    var stepTravel: CGFloat { barePitch * 0.35 }

    /// How far onto the screen a row has to be to count as laid out. The lazy
    /// grid lays out exactly the rows that touch the scroll view; this keeps
    /// clear of the one that only just does.
    private static let laidOut: CGFloat = 2

    /// The least scroll the other way that counts as turning around. The
    /// scroll view's report of a move `growAbove` made can come back a
    /// rounding off, and a rounding the other way taken for a turn would
    /// restart the run — over and over, each start moving the scroll again.
    private static let turnSlop: CGFloat = 0.5

    // MARK: Runs

    /// `state`, with the grid scrolled to `scrolled`, and how far the scroll
    /// view has to be moved to keep what's on screen still: what the rows
    /// above the run grew by (`growAbove`), already counted in the state's
    /// `scrolled`. `end` is as far as it scrolls, `visible` how far below
    /// where its top rests the screen ends, `top` how far above it the screen
    /// starts, and `rows` how many rows it has. With `canShift` false — no
    /// scroll view to move — the rows above the run come on as they are.
    ///
    /// Only scrolling done by hand moves the labels — not a drag's
    /// auto-scroll, nor Add Existing's, nor the offset shifting as the content
    /// changes size under it — and only within the content: a pull past
    /// either end, and the bounce back, isn't going either way. The bounce
    /// off the bottom would bring the labels in. Rows go off the top keeping
    /// their labels however the scroll takes them.
    func state(
        _ state: LibraryLabelState,
        scrolledTo scrolled: CGFloat,
        byHand: Bool,
        end: CGFloat,
        visible: CGFloat,
        top: CGFloat,
        rows: Int,
        canShift: Bool
    ) -> (state: LibraryLabelState, shift: CGFloat) {
        var next = state
        next.top = top
        var shift: CGFloat = 0
        let end = max(end, 0)
        let down = min(max(scrolled, 0), end) - min(max(state.scrolled, 0), end)
        let turning = (down > 0) != state.hiding
        if byHand, down != 0, turning, abs(down) <= Self.turnSlop {
            // Not a turn yet: measured from where it was until it is one, so
            // a slow one adds up rather than going unnoticed frame by frame.
            settleExits(&next, before: state)
            return (next, 0)
        }
        next.scrolled = scrolled
        if byHand, down != 0 {
            // Turning around starts a new run on what's on screen, from the
            // bottom, partway through the last one or not.
            if turning {
                next = run(onScreenIn: next, hiding: down > 0, visible: visible, rows: rows)
            }
            next.progress += abs(down)
            if canShift, !next.hiding { shift = growAbove(&next, by: abs(down)) }
        }
        settleExits(&next, before: state)
        return (next, shift)
    }

    /// `state` with every label from the top of the screen down in: a run over
    /// every row from there to the grid's last, done. The rows above it stay
    /// as they are — the grid hasn't laid them out.
    func showingAll(_ state: LibraryLabelState, rows: Int) -> LibraryLabelState {
        var next = run(onScreenIn: state, hiding: false, visible: .greatestFiniteMagnitude, rows: rows)
        next.startingLabels = Array(repeating: 1, count: next.startingLabels.count)
        return next
    }

    /// A new run over the rows whose labels show in `state` — from the first
    /// whose label sits below the bars, where the grid's top rests, to the
    /// last whose label is on screen — each starting from the label it has, so
    /// nothing moves as it starts, and a row a turn caught part of the way
    /// waits there until its step comes round again. The rows above it keep
    /// what they have.
    private func run(
        onScreenIn state: LibraryLabelState,
        hiding: Bool,
        visible: CGFloat,
        rows: Int
    ) -> LibraryLabelState {
        var run = state
        let first = firstBelowBars(state, rows: rows)
        let bottom = state.scrolled + visible
        var last = first - 1
        while last + 1 < rows, rowTop(last + 1, state) + cover < bottom { last += 1 }
        var above = state.above.filter { $0.key < first }
        for row in state.firstRow..<max(state.firstRow, first) where row <= bottomRow(state) {
            let value = runProgress(row: row, state)
            if value > 0 { above[row] = value }
        }
        run.above = above
        run.firstRow = first
        run.startingLabels = first <= last ? (first...last).map { progress(row: $0, state) } : []
        run.hiding = hiding
        run.progress = 0
        return run
    }

    /// The first row whose label sits below the bars: its covers' bottom at
    /// or below where the grid's top rests.
    private func firstBelowBars(_ state: LibraryLabelState, rows: Int) -> Int {
        var low = 0, high = max(rows, 0)
        while low < high {
            let mid = (low + high) / 2
            if rowTop(mid, state) + cover >= state.scrolled { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Rows of the run gone off the top. The grid stopped laying each out
    /// this frame, so it keeps the label it was last laid out with — the one
    /// in `before`, before this frame's step — and is a row above the run now.
    private func settleExits(_ state: inout LibraryLabelState, before: LibraryLabelState) {
        let screenTop = state.scrolled - state.top
        while state.firstRow <= bottomRow(state) {
            let row = state.firstRow
            let value = runProgress(row: row, state)
            guard rowTop(row, state) + cover + AlbumCard.labelBlock * value <= screenTop else { break }
            let kept = progress(row: row, before)
            if kept > 0 { state.above[row] = kept }
            state.firstRow += 1
            state.startingLabels.removeFirst()
        }
    }

    /// Revealing: each row above the run that the grid has laid out, and
    /// isn't named yet, grows its label by a step's worth of `scrolled` (a
    /// whole label in `stepTravel`), and the scroll is moved by however much
    /// it grew (returned, and in `scrolled` already), so every row below stays
    /// where it is on screen; only the one growing moves, a little behind the
    /// scroll, under the bars. Coming on at the top edge, a row is named well
    /// before it's out from under them.
    private func growAbove(_ state: inout LibraryLabelState, by scroll: CGFloat) -> CGFloat {
        let label = AlbumCard.labelBlock
        let screenTop = state.scrolled - state.top
        var shift: CGFloat = 0
        var row = state.firstRow - 1
        while row >= 0 {
            let value = state.above[row] ?? 0
            let bottom = rowTop(row, state) + cover + label * value
            // Laid out before the scroll moves and after; rows above one off
            // the top are off it too.
            guard bottom > max(screenTop, state.scrolled - state.top) + Self.laidOut else { break }
            if value < 1 {
                let grown = min(1, value + scroll / stepTravel)
                state.above[row] = grown
                shift += label * (grown - value)
                state.scrolled += label * (grown - value)
            }
            row -= 1
        }
        return shift
    }

    // MARK: Rows

    /// How far in row `row`'s label is, 0…1.
    func progress(row: Int, _ state: LibraryLabelState) -> CGFloat {
        if row < state.firstRow { return state.above[row] ?? 0 }
        return runProgress(row: row, state)
    }

    /// The run's last row. Rows past it are bare.
    func bottomRow(_ state: LibraryLabelState) -> Int {
        state.firstRow + state.startingLabels.count - 1
    }

    /// Where the run is taking its rows' labels: away, or back.
    func target(_ state: LibraryLabelState) -> CGFloat {
        state.hiding ? 0 : 1
    }

    /// The row taking its step, and how far through it — nil once the run is
    /// done. Steps go from the run's bottom row up to its top; a row already
    /// where the run is taking it has none. Rows above the run have none at
    /// all: they were off screen when it started.
    func activeStep(_ state: LibraryLabelState) -> (row: Int, done: CGFloat)? {
        let target = target(state)
        var left = state.progress
        for (offset, start) in state.startingLabels.enumerated().reversed() {
            let length = abs(target - start) * stepTravel
            if left < length { return (state.firstRow + offset, left / length) }
            left -= length
        }
        return nil
    }

    /// How far in the label of row `row`, one of the run's, is: where the run
    /// is taking it once its step is past, the step's way through it during,
    /// and as the run found it before.
    func runProgress(row: Int, _ state: LibraryLabelState) -> CGFloat {
        guard row >= state.firstRow else { return state.above[row] ?? 0 }
        guard row <= bottomRow(state) else { return 0 }
        let target = target(state)
        guard let step = activeStep(state), row <= step.row else { return target }
        let start = state.startingLabels[row - state.firstRow]
        guard row == step.row else { return start }
        return start + (target - start) * Self.ease(step.done)
    }

    /// Where row `row`'s covers start, below the grid's top edge.
    func rowTop(_ row: Int, _ state: LibraryLabelState) -> CGFloat {
        CGFloat(row) * barePitch + AlbumCard.labelBlock * labels(above: row, state)
    }

    /// The labels hanging above row `row`, in labels: those of the rows above
    /// the run, then the run's own — as the run found them, the one taking its
    /// step, the done ones, and past the run none.
    private func labels(above row: Int, _ state: LibraryLabelState) -> CGFloat {
        let cut = min(row, state.firstRow)
        var labels = state.above.reduce(CGFloat(0)) { $1.key < cut ? $0 + $1.value : $0 }
        let from = state.firstRow
        let upTo = min(row, bottomRow(state) + 1)
        guard upTo > from else { return labels }
        let target = target(state)
        guard let step = activeStep(state) else {
            return labels + CGFloat(upTo - from) * target
        }
        labels += startingLabels(from: from, upTo: min(upTo, step.row), state)
        if step.row >= from, step.row < upTo {
            labels += runProgress(row: step.row, state)
        }
        labels += CGFloat(max(0, upTo - max(from, step.row + 1))) * target
        return labels
    }

    /// The run's starting labels for its own rows `from..<upTo`.
    private func startingLabels(from: Int, upTo: Int, _ state: LibraryLabelState) -> CGFloat {
        guard upTo > from else { return 0 }
        return state.startingLabels[(from - state.firstRow)..<(upTo - state.firstRow)].reduce(0, +)
    }

    private static func ease(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    // MARK: Scrolling to a row

    /// The scroll that brings row `row` to where the grid's top row rests,
    /// every label from the top of the screen down in (`showingAll`) — or, if
    /// the grid ends first, its end. `end` is as far as it scrolls laid out as
    /// `now`, and `rows` how many rows it has. What Add Existing scrolls to,
    /// so the album it added arrives named. Exact: nothing changes on the way,
    /// rows going off the top keeping their labels.
    func scrollShowing(row: Int, rows: Int, from now: LibraryLabelState, end: CGFloat) -> CGFloat {
        let at = showingAll(now, rows: rows)
        let reach = end + AlbumCard.labelBlock * (labels(above: rows, at) - labels(above: rows, now))
        return max(min(rowTop(row, at), reach), 0)
    }
}

/// The library grid's labels as scrolling has left them: the scroll, the run
/// its labels are coming or going in, and the rows above the run.
///
/// A run starts whenever the scroll turns, over the rows on screen then, and
/// takes them one at a time from the bottom up — away scrolling down, back
/// scrolling up — each starting from the label it had, so a row the turn
/// caught part of the way waits there for its step. `progress` is how far the
/// run has gone; every row past it is bare, and every row above it is as
/// `above` says.
struct LibraryLabelState: Equatable {
    /// How far the grid is scrolled from rest.
    var scrolled: CGFloat = 0
    /// How far above where the grid's top rests the screen starts: the bars,
    /// and the grid's top padding.
    var top: CGFloat = 0
    /// The run's top row…
    var firstRow = 0
    /// …and its rows' labels as it found them, top first. The grid opens on
    /// the rows labelled at rest, a run already done.
    var startingLabels = Array(repeating: CGFloat(1), count: LibraryLabelLine.labelledAtRest)
    /// Whether the run is taking labels away, or giving them back.
    var hiding = false
    /// How far the run has gone, in scroll.
    var progress: CGFloat = 0
    /// The rows above the run that have a label, and how much: what a row of
    /// a run had when it went off the top, or a row coming on from above was
    /// given. The rest above the run are bare.
    var above: [Int: CGFloat] = [:]
}

// MARK: - What the cards read

/// The library grid's labels as its cards read them.
///
/// A few numbers rather than the scroll, each moving only when what it draws
/// does: `stepRow` once a step; `stepProgress` every frame of a step, read
/// only by the row taking it; `firstRow`, `startingLabels` and `above` once a
/// run, as a row goes off the top or comes on from above — `above` read only
/// by the rows above the run; the rest once a run. A scroll frame invalidates
/// the cards whose label is moving rather than a screenful — `ScrollOffsetBox`
/// has the story of what a scroll-driven dependency in the wrong place costs.
@Observable
final class LibraryLabelReveal {
    /// At rest until `place()` says otherwise, so a grid's first frame already
    /// has the rows labelled at rest labelled.
    private(set) var bottomRow = LibraryLabelLine.labelledAtRest - 1
    private(set) var stepRow = -1
    private(set) var stepProgress: CGFloat = 0
    private(set) var target: CGFloat = 1
    private(set) var firstRow = 0
    private(set) var startingLabels = Array(repeating: CGFloat(1), count: LibraryLabelLine.labelledAtRest)
    private(set) var above: [Int: CGFloat] = [:]

    @ObservationIgnored private(set) var state = LibraryLabelState()
    /// Whether someone is scrolling the grid — dragging or flinging it. Only
    /// their scrolling moves the labels.
    @ObservationIgnored var isScrolledByHand = false
    /// How many rows the grid has, so a run doesn't wait on rows that aren't
    /// there.
    @ObservationIgnored var rows = 0
    @ObservationIgnored var line = LibraryLabelLine(cover: 150, gap: 12) {
        didSet { place() }
    }

    /// How far in row `row`'s label is, 0…1: `LibraryLabelLine.progress`,
    /// read off the numbers above, and only the ones the row needs.
    func progress(ofRow row: Int) -> CGFloat {
        if row < firstRow { return above[row] ?? 0 }
        if row > bottomRow { return 0 }
        if row > stepRow { return target }
        if row == stepRow { return stepProgress }
        return startingLabels[row - firstRow]
    }

    /// The grid scrolled to `scrolled`. Returns how far to move the scroll
    /// view to keep what's on screen still (`LibraryLabelLine.state`).
    func scroll(to scrolled: CGFloat, end: CGFloat, visible: CGFloat, top: CGFloat, canShift: Bool) -> CGFloat {
        let (next, shift) = line.state(
            state, scrolledTo: scrolled, byHand: isScrolledByHand,
            end: end, visible: visible, top: top, rows: rows, canShift: canShift
        )
        state = next
        place()
        return shift
    }

    /// Every label from the top of the screen down in, as a long enough
    /// scroll up brings them.
    func showAll() {
        state = line.showingAll(state, rows: rows)
        place()
    }

    private func place() {
        let step = line.activeStep(state)
        bottomRow = line.bottomRow(state)
        stepRow = step?.row ?? -1
        stepProgress = step.map { line.runProgress(row: $0.row, state) } ?? 0
        target = line.target(state)
        firstRow = state.firstRow
        startingLabels = state.startingLabels
        above = state.above
    }
}

/// A card's title block, in the library grid: coming and going with the
/// scroll (`LibraryLabelLine`) — the gap under the cover widening to take it,
/// the words fading up into it, and back. With no row, or anywhere but the
/// library's grid (an open folder's), simply there.
struct LibraryCardLabel<Content: View>: View {
    let row: Int?
    @ViewBuilder let content: Content

    @Environment(LibraryLabelReveal.self) private var reveal: LibraryLabelReveal?
    @Environment(\.folderLabelOpacity) private var folderLabelOpacity

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
            .opacity(shown * shown * folderLabelOpacity)
    }
}

extension EnvironmentValues {
    /// An open folder's titles and artists, faded on their own as it opens
    /// and closes (`FolderZoom`); 1 everywhere else. The panel they're on
    /// only fades for a few hundredths, to make way for the covers flying
    /// in and out, and the words came and went with it at once.
    @Entry var folderLabelOpacity: Double = 1
}

// MARK: - Driving it

extension View {
    /// Label this scroll view's library grid, `rows` rows laid out by `line`
    /// from `inset` below the top of its content: owns the
    /// `LibraryLabelReveal` the cards inside read, and moves it with the
    /// scroll. Every label comes in whenever `showAll` changes, as a long
    /// enough scroll up would bring them. `scrollView` is the scroll view
    /// itself, which a row coming on named moves to keep what's on screen
    /// still; `offset` the ornaments' box, fed from here in place of
    /// `tracksScrollOffset`, so that move is never taken for a scroll
    /// (`ScrollOffsetBox.follow`). `onScroll` hears each new state, for
    /// arithmetic that has to agree with what the cards draw
    /// (`LibraryGridGeometry.labels`).
    func revealsLibraryLabels(
        _ line: LibraryLabelLine,
        rows: Int,
        inset: CGFloat,
        showingAllOn showAll: Int,
        scrollView: @escaping () -> UIScrollView?,
        offset: ScrollOffsetBox,
        onScroll: @escaping (LibraryLabelState) -> Void
    ) -> some View {
        modifier(LibraryLabelRevealHost(
            line: line, rows: rows, inset: inset, showAll: showAll,
            scrollView: scrollView, offset: offset, onScroll: onScroll
        ))
    }
}

/// Holds the reveal for exactly as long as the scroll view it measures. A grid
/// built fresh — a library switch, the list toggled back to the grid — starts
/// at rest, and so does a reveal built with it; one kept by the library would
/// carry the last grid's scroll into the new one.
private struct LibraryLabelRevealHost: ViewModifier {
    let line: LibraryLabelLine
    let rows: Int
    let inset: CGFloat
    let showAll: Int
    let scrollView: () -> UIScrollView?
    let offset: ScrollOffsetBox
    let onScroll: (LibraryLabelState) -> Void

    @State private var reveal = LibraryLabelReveal()

    func body(content: Content) -> some View {
        content
            .environment(reveal)
            .onScrollPhaseChange { _, phase in
                reveal.isScrolledByHand = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: ScrollReach.self) { geometry in
                // `containerSize` is the scroll view less its insets, not the
                // scroll view: 652pt of an 874pt one under 116pt of bars and
                // the 106pt band the + button and the mini player float in,
                // measured on a phone. Taken for the whole height, it ended
                // the screen 222pt short, so a run left out the rows whose
                // labels showed in that stretch and a turn down took theirs
                // at once — and it let the scroll run 222pt past its end.
                let insets = geometry.contentInsets.top + geometry.contentInsets.bottom
                return ScrollReach(
                    offset: geometry.contentOffset.y,
                    inset: geometry.contentInsets.top,
                    insetBottom: geometry.contentInsets.bottom,
                    end: geometry.contentSize.height - geometry.containerSize.height,
                    height: geometry.containerSize.height + insets
                )
            } action: { _, reach in
                // Measured from rest. At rest `contentOffset` is minus the
                // bars' height, not zero.
                let scrollView = scrollView()
                #if DEBUG
                let before = reveal.state
                #endif
                let shift = reveal.scroll(
                    to: reach.offset + reach.inset,
                    end: reach.end,
                    visible: reach.height - reach.inset - inset,
                    top: reach.inset + inset,
                    canShift: scrollView != nil
                )
                // Here, in the frame of the labels it makes up for: a frame
                // later and the screen jumps by them, and back.
                if shift != 0 { scrollView?.contentOffset.y += shift }
                offset.follow(reach.offset, shifted: shift)
                // Written only when the inset itself changes, which is what an
                // observer pays for.
                if offset.top != -reach.inset { offset.top = -reach.inset }
                #if DEBUG
                LibraryLabelLog.report(
                    before, reveal.state, line: line, rows: rows, height: reach.height,
                    insets: (reach.inset, reach.insetBottom), byHand: reveal.isScrolledByHand,
                    shift: shift, frame: scrollView.map { $0.convert($0.bounds, to: nil) }
                )
                #endif
                onScroll(reveal.state)
            }
            .onChange(of: rows, initial: true) {
                reveal.rows = rows
            }
            .onChange(of: line, initial: true) {
                reveal.line = line
                onScroll(reveal.state)
            }
            .onChange(of: showAll) {
                reveal.showAll()
                onScroll(reveal.state)
            }
    }
}

/// The scroll view's offset and insets as it reports them, how far from rest
/// it can go, and how tall it is — all of it, under the bars and the band at
/// the bottom included, which show what's under them.
private struct ScrollReach: Equatable {
    var offset: CGFloat
    var inset: CGFloat
    var insetBottom: CGFloat
    var end: CGFloat
    var height: CGFloat
}

#if DEBUG
/// `[Labels]`: each turn, with the run and the scroll's geometry, and any label
/// whose room shows on screen changing by more than a frame of a step at the
/// scroll's speed — a snap — with what was around it.
private enum LibraryLabelLog {
    static func report(
        _ before: LibraryLabelState,
        _ after: LibraryLabelState,
        line: LibraryLabelLine,
        rows: Int,
        height: CGFloat,
        insets: (top: CGFloat, bottom: CGFloat),
        byHand: Bool,
        shift: CGFloat,
        frame: CGRect?
    ) {
        func f(_ x: CGFloat) -> String { String(format: "%.1f", Double(x)) }
        func run(_ st: LibraryLabelState) -> String {
            "\(st.hiding ? "hide" : "reveal") \(st.firstRow)…\(line.bottomRow(st)) ["
                + st.startingLabels.map { String(format: "%.2f", Double($0)) }.joined(separator: " ") + "]"
        }
        /// Where row `row`'s label room starts on screen, from the scroll view's top.
        func labelTop(_ row: Int, _ st: LibraryLabelState) -> CGFloat {
            line.rowTop(row, st) + line.cover - (st.scrolled - st.top)
        }
        func shows(_ row: Int, _ st: LibraryLabelState) -> Bool {
            let y = labelTop(row, st)
            return y + AlbumCard.labelBlock > 4 && y < height
        }
        let hand = after.scrolled - shift - before.scrolled
        if after.hiding != before.hiding {
            let lowest = (0..<rows).last { shows($0, after) }
            print("[Labels] turn → \(run(after)) by hand \(byHand) hand \(f(hand)) scrolled \(f(after.scrolled)) top \(f(after.top))"
                + " height \(f(height)) insets \(f(insets.top))/\(f(insets.bottom)) frame \(frame.map { "\(f($0.minY))…\(f($0.maxY))" } ?? "-")"
                + " lowest showing \(lowest.map { "\($0) label at \(f(labelTop($0, after))) = \(String(format: "%.2f", Double(line.progress(row: $0, before))))" } ?? "-")")
        }
        let allowed = max(0.12, 1.6 * abs(hand) / line.stepTravel)
        for row in 0..<rows {
            if line.rowTop(row, after) - (after.scrolled - after.top) > height { break }
            guard shows(row, before), shows(row, after) else { continue }
            let d = line.progress(row: row, after) - line.progress(row: row, before)
            guard abs(d) > allowed else { continue }
            print("[Labels] SNAP row \(row) \(String(format: "%.2f → %.2f", Double(line.progress(row: row, before)), Double(line.progress(row: row, after))))"
                + " label at \(f(labelTop(row, after))) of \(f(height)) hand \(f(hand)) shift \(f(shift)) by hand \(byHand)"
                + " | before \(run(before)) | after \(run(after))")
        }
    }
}
#endif
