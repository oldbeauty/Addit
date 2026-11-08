import SwiftUI
import SwiftData
import UIKit

// MARK: - Items

/// One thing on a library's top level: an album, or a folder of them.
enum LibraryItem: Identifiable {
    case album(Album)
    case folder(LibraryFolder)

    var id: LibraryItemID {
        switch self {
        case .album(let album): .album(album.persistentModelID)
        case .folder(let folder): .folder(folder.folderID)
        }
    }
}

enum LibraryItemID: Hashable {
    case album(PersistentIdentifier)
    case folder(String)

    var isFolder: Bool {
        if case .folder = self { true } else { false }
    }
}

/// The library as the grid draws it: the top level in order, and each
/// folder's albums in order. Built by `LibraryView.libraryArrangement()`, the
/// one place that decides what a library contains and where.
struct LibraryArrangement {
    var items: [LibraryItem] = []
    var contents: [String: [Album]] = [:]
}

/// Which grid a drag is in: the library's own, or an open folder's.
enum LibraryDragZone: Equatable {
    case grid
    case panel(String)
}

// MARK: - Geometry

/// Where the cells of one grid are — worked out, not measured.
///
/// The grids are `LazyVGrid`s, which only build the cells on screen, so they
/// can't be asked where slot 40 is, and a drag that auto-scrolls needs exactly
/// that. Every card in a row is the same size — a cover plus however much of
/// `AlbumCard.labelBlock` the row is showing — so a slot is arithmetic on the
/// grid's origin, and the origin is the one thing measured (`onGeometryChange`,
/// into the arranger's coordinate space). In an open folder every row shows
/// all of its label; in the library's own grid that depends on the scroll,
/// and `LibraryLabelLine` — the same arithmetic the cards are drawn from — says
/// how much.
struct LibraryGridGeometry {
    var origin: CGPoint = .zero
    var columns = 2
    var cover: CGFloat = 150
    var columnSpacing: CGFloat = 30
    var rowSpacing: CGFloat = 16
    /// Labels that come and go with the scroll, as the library's own grid
    /// draws them. Off — an open folder — every row is labelled.
    var revealsLabels = false
    /// The labels as scrolling has left them, which `revealsLabels` rows are
    /// placed by. A copy kept here, unobserved, rather than a read of the
    /// cards' `LibraryLabelReveal`: `LibraryView.body` asks where a folder's
    /// tile is, and must never come to depend on the scroll.
    var labels = LibraryLabelState()

    private var columnPitch: CGFloat { cover + columnSpacing }
    /// The most a row can take up, cover top to cover top: label showing.
    private var tallestPitch: CGFloat { cover + AlbumCard.labelBlock + rowSpacing }

    /// Where row `row`'s covers start, below `origin`.
    private func rowTop(_ row: Int) -> CGFloat {
        guard revealsLabels else { return CGFloat(row) * tallestPitch }
        return LibraryLabelLine(cover: cover, gap: rowSpacing).rowTop(row, labels)
    }

    /// How much label hangs under row `row`'s covers.
    private func labelHeight(_ row: Int) -> CGFloat {
        guard revealsLabels else { return AlbumCard.labelBlock }
        return AlbumCard.labelBlock
            * LibraryLabelLine(cover: cover, gap: rowSpacing).progress(row: row, labels)
    }

    /// The card under `point`, if any. Gutters hit nothing, so a hold between
    /// two covers is left to the scroll view.
    func itemIndex(at point: CGPoint, count: Int) -> Int? {
        let x = point.x - origin.x, y = point.y - origin.y
        guard x >= 0, y >= 0, columns > 0 else { return nil }
        let column = Int(x / columnPitch)
        // The last row to start at or above `y`. No row is taller than
        // `tallestPitch`, so row `y / tallestPitch` has certainly started;
        // walk on from there.
        var row = Int(y / tallestPitch)
        while rowTop(row + 1) <= y { row += 1 }
        guard column < columns,
              x - CGFloat(column) * columnPitch <= cover,
              y - rowTop(row) <= cover + labelHeight(row)
        else { return nil }
        let index = row * columns + column
        return index < count ? index : nil
    }

    /// Where a cover centred at `point` would land: the nearest slot, clamped
    /// into the list so anywhere past the end means last — and, when it is
    /// over the middle of another cover, that cover, as somewhere to merge.
    ///
    /// Slots are divided halfway between neighbouring cover *centres*, not at
    /// the cells' edges: the label hangs below every cover, and cutting rows at
    /// the cell edge would put the boundary a label's height off-centre.
    func slot(for point: CGPoint, count: Int) -> (index: Int, over: Int?) {
        guard count > 0, columns > 0 else { return (0, nil) }
        let x = point.x - origin.x, y = point.y - origin.y
        let column = min(max(Int(floor((x + (columnPitch - cover) / 2) / columnPitch)), 0), columns - 1)
        // The last row whose boundary with the row above — halfway between
        // their cover centres — is at or above `y`. A row's boundary is never
        // below its own cover's centre, so from where that has certainly been
        // passed, walk on.
        var row = max(Int(floor((y - cover / 2) / tallestPitch)), 0)
        while (rowTop(row) + rowTop(row + 1)) / 2 + cover / 2 <= y { row += 1 }
        let raw = row * columns + column
        var over: Int?
        if raw < count {
            let coverRect = CGRect(
                x: CGFloat(column) * columnPitch, y: rowTop(row),
                width: cover, height: cover
            )
            // The middle half, roughly: near enough the centre to mean "onto",
            // with margins wide enough that sliding between two covers still
            // means "between".
            if coverRect.insetBy(dx: cover * 0.24, dy: cover * 0.24).contains(CGPoint(x: x, y: y)) {
                over = raw
            }
        }
        return (min(raw, count - 1), over)
    }

    /// The centre of slot `index`'s cover, in the space `origin` is in.
    func coverCenter(of index: Int) -> CGPoint {
        let columns = max(self.columns, 1)
        return CGPoint(
            x: origin.x + CGFloat(index % columns) * columnPitch + cover / 2,
            y: origin.y + rowTop(index / columns) + cover / 2
        )
    }
}

// MARK: - Arranger

/// The Home Screen's edit mode, for the library: jiggle, drag to reorder,
/// drop one album on another to make a folder, drag out of a folder to take
/// an album back out.
///
/// Owned by `LibraryView`, but split so that the view's `body` never depends
/// on anything that changes per frame. The observed properties here change a
/// handful of times a drag; `liftPoint` changes every frame and is read only by
/// `LiftedItemLayer`. Reading it anywhere in `LibraryView.body` would re-run
/// the library's filtering passes — SwiftData reads, every one — per touch
/// event, the same trap `ScrollOffsetBox` exists to avoid.
///
/// The model is written *live* as the hole moves, not at the drop: every
/// reorder is a renumbering of `displayOrder`, animated, and the grid simply
/// redraws what the store says. There is no second copy of the order to fall
/// out of step with it.
@Observable
final class LibraryArranger {
    /// The space every grid, the open folder and the lifted card report in:
    /// `LibraryView`'s whole frame, overlays included.
    static let coordinateSpace = NamedCoordinateSpace.named("libraryArrange")

    /// How long a card must be held before arrange mode takes over from the
    /// context menu — the menu comes up at about half a second, so this is
    /// "keep holding".
    static let holdToArrange: TimeInterval = 1.1
    /// How long a card must be held, once arranging, before it lifts. Longer
    /// than the Home Screen's (none): its pages turn sideways, while this grid
    /// scrolls under the same finger, and a flick has to stay a scroll.
    static let holdToPickUp: TimeInterval = 0.18

    private static let reflow: Animation = .snappy(duration: 0.3)
    /// The card in hand, a little larger than the covers it's carried over.
    private static let liftScale: CGFloat = 1.1
    /// …and while it's held where letting go would make a folder or drop into
    /// one: smaller than the cover under it, so that cover and the plate
    /// forming behind it show round the card. At its lifted size, centred over
    /// the cover as a merge is aimed, it hid both, and nothing said a folder
    /// was coming until one appeared.
    private static let mergeScale: CGFloat = 0.8
    /// Into a folder: a soft spring, the way the Home Screen's icons drift in,
    /// where a card going home snaps.
    static let settle: Animation = .spring(duration: 0.42, bounce: 0.08)
    /// A pause, for the dwell: the finger staying within this of where it was.
    private static let pauseSlop: CGFloat = 8

    // MARK: Observed — each changes a few times a drag at most

    var isArranging = false
    /// The folder whose layer is up. Setting it puts the layer up *collapsed*,
    /// exactly over the folder's tile; `isFolderExpanded` is what grows it.
    var openFolderID: String? {
        didSet {
            guard (openFolderID == nil) != (oldValue == nil) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isLibraryBarCleared = openFolderID != nil }
        }
    }
    /// The library's own controls — its toolbar items, the add button — are
    /// away, because a folder is up: `openFolderID`, on a fade of its own. The
    /// bar changes on the frames the layer goes up and comes down, which must
    /// not animate — the layer appears and vanishes exactly over its tile — so
    /// keyed on `openFolderID` itself, the items blinked off at the tap and
    /// back on as the folder landed.
    private(set) var isLibraryBarCleared = false
    /// The open folder is open, as opposed to growing out of its tile or
    /// shrinking back into it. Read by `FolderZoom` alone — anything in
    /// `LibraryView.body` keyed on it would re-run the library on the
    /// spring's first frame. False whenever `openFolderID` is nil.
    var isFolderExpanded = false
    /// The open folder's titles and artists are showing: in as it opens, out
    /// just before it closes (`FolderMotion.labelsIn`, `closeFolder`). Read by
    /// `FolderZoom` alone, like the spring.
    var areFolderLabelsShown = false
    /// The open folder has faded because its album was dragged out, but stays
    /// in the hierarchy until the drop: the recognizer carrying the drag is
    /// attached to it, and removing the view would cancel the drag.
    var folderHiddenForDrag = false
    var draggedItem: LibraryItemID?
    var mergeTarget: LibraryItemID?
    var lifted: LiftedCard?
    /// A new folder's first album, settling into its tile beside the card in
    /// hand, from the drop to the landing.
    var settling: SettlingCover?

    /// Albums whose covers in a folder's tile wait unseen for the card
    /// settling onto them (`drop`): the one in hand, and a new folder's first.
    var arrivingAlbums: Set<PersistentIdentifier> {
        var ids: Set<PersistentIdentifier> = []
        if case .album(let id)? = draggedItem { ids.insert(id) }
        if let settling { ids.insert(settling.album.persistentModelID) }
        return ids
    }
    /// "Sort by Color" is reading covers. Nothing may be picked up, opened or
    /// closed meanwhile — it's about to renumber everything on screen.
    var isSortingByColor = false
    /// What the last colour sort overwrote, while it can still be put back.
    var colorSortUndo: ColorSortUndo?

    // MARK: Observed per frame — read by `LiftedItemLayer` and nothing else

    var liftPoint: CGPoint = .zero

    // MARK: Not observed

    @ObservationIgnored var grid = LibraryGridGeometry(revealsLabels: true)
    @ObservationIgnored var panel = LibraryGridGeometry()
    @ObservationIgnored var gridViewport: CGRect = .zero
    @ObservationIgnored var panelViewport: CGRect = .zero
    /// Where each folder's tile is in list layout, which has no arithmetic to
    /// work it out from — measured, for an open folder to grow out of.
    @ObservationIgnored var rowTileFrames: [String: CGRect] = [:]
    @ObservationIgnored weak var gridScrollView: UIScrollView?
    @ObservationIgnored weak var panelScrollView: UIScrollView?
    @ObservationIgnored private var session: DragSession?
    /// The drop whose card is still flying home, if one is (`land`).
    @ObservationIgnored private var landing: UUID?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    /// Where the finger was when the current dwell started. Moving further
    /// than `pauseSlop` from it starts the dwell over.
    @ObservationIgnored private var dwellAnchor: CGPoint = .zero
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    @ObservationIgnored private var autoscroll: FrameTicker?
    /// When the recognizer carrying the card was first seen carrying nothing
    /// (`putDownIfAbandoned`).
    @ObservationIgnored private var uncarriedSince: CFTimeInterval?

    /// A card is in hand or still flying home, or a colour sort is under way.
    /// Nothing else may start then.
    var isBusy: Bool { session != nil || landing != nil || isSortingByColor }

    func hasCard(at point: CGPoint, in zone: LibraryDragZone, count: Int) -> Bool {
        geometry(for: zone).itemIndex(at: point, count: count) != nil
    }

    private func geometry(for zone: LibraryDragZone) -> LibraryGridGeometry {
        zone == .grid ? grid : panel
    }

    // MARK: Pick up

    func pickUp(
        at point: CGPoint,
        in zone: LibraryDragZone,
        carriedBy recognizer: UIGestureRecognizer,
        arrangement: LibraryArrangement,
        context: ModelContext,
        makeFolder: @escaping () -> LibraryFolder
    ) {
        guard !isBusy else { return }
        let panelAlbums: [Album]
        if case .panel(let folderID) = zone {
            panelAlbums = arrangement.contents[folderID] ?? []
        } else {
            panelAlbums = []
        }
        let geometry = geometry(for: zone)
        let count = zone == .grid ? arrangement.items.count : panelAlbums.count
        guard let index = geometry.itemIndex(at: point, count: count) else { return }

        var albums: [PersistentIdentifier: Album] = [:]
        var folders: [String: LibraryFolder] = [:]
        for item in arrangement.items {
            switch item {
            case .album(let album): albums[album.persistentModelID] = album
            case .folder(let folder): folders[folder.folderID] = folder
            }
        }
        for list in arrangement.contents.values {
            for album in list { albums[album.persistentModelID] = album }
        }

        // Moving something by hand ends the chance to undo a colour sort:
        // undoing it afterwards would quietly take this move back too.
        colorSortUndo = nil

        let card: LibraryItem = zone == .grid ? arrangement.items[index] : .album(panelAlbums[index])
        var contents: [Album] = []
        if case .folder(let folder) = card { contents = arrangement.contents[folder.folderID] ?? [] }
        let center = geometry.coverCenter(of: index)

        let session = DragSession(
            item: card.id,
            zone: zone,
            recognizer: recognizer,
            grabOffset: CGSize(width: center.x - point.x, height: center.y - point.y),
            finger: point,
            gridOrder: arrangement.items.map(\.id),
            panelOrder: panelAlbums.map(\.persistentModelID),
            albums: albums,
            folders: folders,
            context: context,
            makeFolder: makeFolder
        )
        // Dense orders from the first frame: ties in `displayOrder` (two
        // albums added at once, a folder and the album after it) are broken by
        // the sort, and what gets written back has to be exactly what's on
        // screen, not a renumbering of what the store happened to hold.
        session.writeGridOrder()
        session.writeFolderOrder(session.panelOrder)
        self.session = session
        dwellAnchor = point
        uncarriedSince = nil

        liftPoint = center
        lifted = LiftedCard(item: card, contents: contents, size: geometry.cover)
        draggedItem = card.id
        withAnimation(.snappy(duration: 0.22)) { lifted?.scale = Self.liftScale }
        startAutoscroll()
    }

    // MARK: Move

    func drag(to point: CGPoint) {
        guard let session else { return }
        self.session?.finger = point
        liftPoint = CGPoint(x: point.x + session.grabOffset.width, y: point.y + session.grabOffset.height)
        evaluate(immediate: false)
    }

    /// Decide what the card is over. `immediate` is auto-scroll's: the content
    /// is moving under a still finger, the hole has to keep up with it, and a
    /// merge would be an accident at that speed — so no dwell and no merging.
    private func evaluate(immediate: Bool) {
        guard let session else { return }
        switch session.zone {
        case .panel(let folderID):
            if panelViewport.insetBy(dx: -20, dy: -20).contains(session.finger) {
                leaveTask?.cancel()
                leaveTask = nil
                let slot = panel.slot(for: liftPoint, count: session.panelOrder.count)
                propose(.reorder(slot.index), immediate: immediate)
            } else if leaveTask == nil {
                dwellTask?.cancel()
                self.session?.pending = nil
                leaveTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    self?.leaveFolder(folderID)
                }
            }
        case .grid:
            let slot = grid.slot(for: liftPoint, count: session.gridOrder.count)
            // Folders don't nest, and a folder dropped on anything just moves.
            if !immediate, !session.item.isFolder, let over = slot.over, session.gridOrder[over] != session.item {
                propose(.merge(session.gridOrder[over]), immediate: false)
            } else {
                propose(.reorder(slot.index), immediate: immediate)
            }
        }
    }

    /// Nothing happens because the card *passes* somewhere — only where it
    /// pauses. Briefly, and the covers make room; longer over the middle of
    /// one, and it offers to become a folder. The pause is what lets a card
    /// travel to a cover's centre without shoving that cover aside on the way,
    /// and it's why the Home Screen feels deliberate rather than twitchy: a
    /// moving finger keeps restarting the clock.
    private func propose(_ candidate: DropCandidate, immediate: Bool) {
        guard let session else { return }
        if let mergeTarget, candidate != .merge(mergeTarget) {
            withAnimation(.snappy(duration: 0.2)) {
                self.mergeTarget = nil
                lifted?.scale = Self.liftScale
            }
        }
        if immediate {
            dwellTask?.cancel()
            self.session?.pending = candidate
            apply(candidate)
            return
        }
        let strayed = hypot(session.finger.x - dwellAnchor.x, session.finger.y - dwellAnchor.y) > Self.pauseSlop
        guard candidate != session.pending || strayed else { return }
        self.session?.pending = candidate
        dwellAnchor = session.finger
        dwellTask?.cancel()
        let delay: Duration
        if case .merge = candidate { delay = .milliseconds(400) } else { delay = .milliseconds(150) }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.session?.pending == candidate else { return }
            self.apply(candidate)
        }
    }

    private func apply(_ candidate: DropCandidate) {
        guard var session else { return }
        switch candidate {
        case .merge(let target):
            guard mergeTarget != target else { return }
            withAnimation(.snappy(duration: 0.22)) {
                mergeTarget = target
                lifted?.scale = Self.mergeScale
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .reorder(let index):
            switch session.zone {
            case .grid:
                guard let from = session.gridOrder.firstIndex(of: session.item), from != index else { return }
                session.gridOrder.remove(at: from)
                session.gridOrder.insert(session.item, at: min(index, session.gridOrder.count))
                self.session = session
                withAnimation(Self.reflow) { session.writeGridOrder() }
            case .panel:
                guard case .album(let id) = session.item,
                      let from = session.panelOrder.firstIndex(of: id), from != index else { return }
                session.panelOrder.remove(at: from)
                session.panelOrder.insert(id, at: min(index, session.panelOrder.count))
                self.session = session
                withAnimation(Self.reflow) { session.writeFolderOrder(session.panelOrder) }
            }
        }
    }

    /// The card has been held outside the open folder: take it out. The folder
    /// fades but stays mounted (`folderHiddenForDrag`), and the drag carries on
    /// in the library's grid from wherever the card now is.
    private func leaveFolder(_ folderID: String) {
        leaveTask = nil
        guard var session, session.zone == .panel(folderID),
              case .album(let id) = session.item, let album = session.albums[id] else { return }
        session.panelOrder.removeAll { $0 == id }
        // Emptied, the folder is gone from the grid now; its row is pruned
        // when arranging ends, once nothing on screen can still be holding it.
        if session.panelOrder.isEmpty {
            session.gridOrder.removeAll { $0 == .folder(folderID) }
        }
        let slot = grid.slot(for: liftPoint, count: session.gridOrder.count + 1)
        session.gridOrder.insert(session.item, at: min(slot.index, session.gridOrder.count))
        session.zone = .grid
        session.pending = nil
        self.session = session
        withAnimation(Self.reflow) {
            album.libraryFolderID = nil
            session.writeFolderOrder(session.panelOrder)
            session.writeGridOrder()
            folderHiddenForDrag = true
            lifted?.size = grid.cover
        }
    }

    // MARK: Drop

    func drop(cancelled: Bool) {
        dwellTask?.cancel()
        leaveTask?.cancel()
        leaveTask = nil
        autoscroll?.stop()
        autoscroll = nil
        // Let go without pausing, the card still lands where it was let go —
        // the pause only decides what happens *on the way*. A folder, though,
        // has to have been offered first.
        if !cancelled, mergeTarget == nil, let session {
            switch session.zone {
            case .grid:
                apply(.reorder(grid.slot(for: liftPoint, count: session.gridOrder.count).index))
            case .panel:
                if panelViewport.insetBy(dx: -20, dy: -20).contains(session.finger) {
                    apply(.reorder(panel.slot(for: liftPoint, count: session.panelOrder.count).index))
                }
            }
        }
        guard var session else { return }
        self.session = nil
        let flight = UUID()
        landing = flight

        let destination: CGPoint
        var endScale: CGFloat = 1
        var endOpacity: Double = 1
        var createdFolderID: String?
        var merged: (folder: LibraryItemID, slot: Int)?

        let target = !cancelled && session.zone == .grid ? mergeTarget : nil
        // Where the target's cover is now, before the merge takes its slot.
        let targetCenter = target.flatMap { session.gridOrder.firstIndex(of: $0) }.map { grid.coverCenter(of: $0) }
        if let target {
            // A new folder takes the target's place at once: its first album
            // is drawn from that very place (`settling`), and a target faded
            // out there would be a second copy of it left behind.
            merged = formFolder(around: target, session: &session, createdFolderID: &createdFolderID)
            if merged != nil { session.writeGridOrder() }
        }

        if let merged, case .folder(let folderID) = merged.folder {
            // Into the folder as on the Home Screen: onto the very cover it
            // becomes in the tile, at that cover's size, which waits unseen
            // until it lands (`arrivingAlbums`), so the handover is the same
            // picture in the same place. It shrank to a third at the tile's
            // middle and faded, and the tile already showed it: a snap. Past
            // the tile's four there's no cover to become, so into the tile.
            // Aimed at where the folder stands once the hole has closed.
            let item = session.item
            let settledOrder = session.gridOrder.filter { $0 != item }
            let center = grid.coverCenter(of: settledOrder.firstIndex(of: merged.folder) ?? 0)
            let corner = CGPoint(x: center.x - grid.cover / 2, y: center.y - grid.cover / 2)
            if merged.slot < FolderTile.capacity {
                let mini = FolderTile.miniFrame(merged.slot, size: grid.cover)
                destination = CGPoint(x: corner.x + mini.midX, y: corner.y + mini.midY)
                endScale = mini.width / (lifted?.size ?? grid.cover)
            } else {
                destination = center
                endScale = 0.35
                endOpacity = 0
            }
            // A new folder's first album draws back from where it stood into
            // its own corner, the plate that formed behind it thinning away.
            if createdFolderID != nil, case .album(let id)? = target,
               let album = session.albums[id], let targetCenter {
                let mini = FolderTile.miniFrame(0, size: grid.cover)
                settling = SettlingCover(
                    album: album,
                    size: grid.cover,
                    from: targetCenter,
                    to: CGPoint(x: corner.x + mini.midX, y: corner.y + mini.midY),
                    fromScale: ArrangeChrome.drawBack,
                    toScale: mini.width / grid.cover,
                    plateTo: center
                )
            }
            // The album goes in, and its hole closes, a turn later on the
            // card's own spring, so the covers after it drift up into the
            // gap as it settles. In the update that made the folder, which
            // mustn't animate, the hole shut with it, at once.
            var admitting = session
            DispatchQueue.main.async {
                withAnimation(Self.settle) { Self.admit(&admitting, into: folderID) }
                try? admitting.context.save()
            }
        } else {
            switch session.zone {
            case .grid:
                destination = grid.coverCenter(of: session.gridOrder.firstIndex(of: session.item) ?? 0)
            case .panel:
                var index = 0
                if case .album(let id) = session.item { index = session.panelOrder.firstIndex(of: id) ?? 0 }
                destination = panel.coverCenter(of: index)
            }
        }
        try? session.context.save()

        // Home: over the hole, at rest size, so the lifted copy and the cell it
        // came from are the same picture at the moment one replaces the other.
        // Either way the lift's shadow thins as it comes down, rather than
        // going at the swap.
        let closesFolder = folderHiddenForDrag
        let newFolderID = createdFolderID
        withAnimation(merged != nil ? Self.settle : .snappy(duration: 0.3)) {
            liftPoint = destination
            lifted?.scale = endScale
            lifted?.opacity = endOpacity
            lifted?.shadow = 0
            mergeTarget = nil
        } completion: { [weak self] in
            self?.land(flight, closesFolder: closesFolder, newFolderID: newFolderID)
        }
        // What lands the card is that completion, and it's SwiftUI's to call.
        // If it never does, `landing` never clears, and `isBusy` with it: the
        // screen looks as it always does, every card jiggling and the card
        // already home, but none will lift and Done does nothing. That's how
        // a tester described being stuck on build 12 — no card left floating,
        // which a lost drag would have left (`putDownIfAbandoned`). So the
        // landing has a deadline too, well past the animation's length.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.land(flight, closesFolder: closesFolder, newFolderID: newFolderID)
        }
    }

    /// The card in hand is home: the real one takes its place again. Run by
    /// the landing animation's completion or its deadline, whichever comes
    /// first, and only for the drop it belongs to — so the later of the two
    /// can't reopen a folder since closed, or land a drop since begun.
    private func land(_ flight: UUID, closesFolder: Bool, newFolderID: String?) {
        guard landing == flight else { return }
        landing = nil
        draggedItem = nil
        lifted = nil
        settling = nil
        if closesFolder {
            openFolderID = nil
            isFolderExpanded = false
            areFolderLabelsShown = false
            folderHiddenForDrag = false
        }
        // A new folder opens on arrival, as on the Home Screen — the name
        // is right there to change. It grows out of the tile the card just
        // shrank into.
        if let newFolderID { openFolderID = newFolderID }
    }

    /// The first half of dropping the dragged album onto `target`, made at
    /// once: an album target becomes a new folder in its own place, holding
    /// it; a folder target is as it is. Returns the folder the card flies
    /// into and the place the album will take in it, or nil if the merge
    /// can't happen and this is an ordinary drop. `admit` is the other half.
    private func formFolder(
        around target: LibraryItemID,
        session: inout DragSession,
        createdFolderID: inout String?
    ) -> (folder: LibraryItemID, slot: Int)? {
        guard case .album(let draggedID) = session.item, session.albums[draggedID] != nil else { return nil }
        switch target {
        case .folder(let folderID):
            return (target, session.albums.values.filter { $0.libraryFolderID == folderID }.count)
        case .album(let targetID):
            guard let targetAlbum = session.albums[targetID],
                  let slot = session.gridOrder.firstIndex(of: target) else { return nil }
            let folder = session.makeFolder()
            session.context.insert(folder)
            session.folders[folder.folderID] = folder
            targetAlbum.libraryFolderID = folder.folderID
            targetAlbum.libraryFolderOrder = 0
            session.gridOrder[slot] = .folder(folder.folderID)
            createdFolderID = folder.folderID
            return (.folder(folder.folderID), 1)
        }
    }

    /// The second half, animated: the dragged album into `folderID`, last,
    /// and the hole it left in the grid closed.
    private static func admit(_ session: inout DragSession, into folderID: String) {
        guard case .album(let draggedID) = session.item, let dragged = session.albums[draggedID] else { return }
        let inside = session.albums.values.filter { $0.libraryFolderID == folderID }
        dragged.libraryFolderID = folderID
        // Last, as on the Home Screen: after the highest order there, which
        // isn't always the count — orders can have gaps, and the count could
        // put it among them, short of the cover it flies to.
        dragged.libraryFolderOrder = (inside.map(\.libraryFolderOrder).max() ?? -1) + 1
        let item = session.item
        session.gridOrder.removeAll { $0 == item }
        session.writeGridOrder()
    }

    // MARK: Auto-scroll

    /// Held near the top or bottom of whichever grid the card is in, the grid
    /// scrolls — faster the closer to the edge. A loop rather than a reaction
    /// to movement, because the whole point is a finger holding still.
    ///
    /// The loop is the display's (`FrameTicker`), and each step covers the
    /// time since the last. It was a task sleeping 16ms between steps of a
    /// fixed size: never in step with the frames, so the grid moved twice on
    /// some and not at all on others, and slowed whenever the main thread was
    /// busy — a judder, right under the card in hand.
    ///
    /// The scroll view is driven directly (`EnclosingScrollViewReader` found
    /// it) rather than through a SwiftUI `ScrollPosition`, which would be a
    /// state change on `LibraryView` every frame of the scroll.
    private func startAutoscroll() {
        autoscroll?.stop()
        let ticker = FrameTicker { [weak self] elapsed in
            guard let self, self.session != nil, !self.putDownIfAbandoned() else { return false }
            self.autoscrollStep(elapsed)
            return true
        }
        autoscroll = ticker
        ticker.start()
    }

    /// A drag never outlives the touch carrying it. The recognizer's end is
    /// what drops the card, and nothing else does: if that end is lost — the
    /// view it's attached to taken down with the card in hand, say — the
    /// session stays open, and with it `isBusy`. Every card then refuses to
    /// lift and Done does nothing, with the card left floating where the
    /// finger let go. So each frame of a drag, on the auto-scroll's clock,
    /// also asks the recognizer itself. One that has carried nothing — gone,
    /// or back to waiting for a touch — for longer than an end takes to
    /// arrive lands the card in its hole, as a cancelled drag would. True if
    /// it did.
    private func putDownIfAbandoned() -> Bool {
        switch session?.recognizer?.state {
        case .began?, .changed?:
            uncarriedSince = nil
            return false
        default:
            let now = CACurrentMediaTime()
            guard let since = uncarriedSince else {
                uncarriedSince = now
                return false
            }
            guard now - since > 0.25 else { return false }
            uncarriedSince = nil
            drop(cancelled: true)
            return true
        }
    }

    private func autoscrollStep(_ elapsed: CFTimeInterval) {
        guard let session else { return }
        let scrollView: UIScrollView?
        let viewport: CGRect
        switch session.zone {
        case .grid: (scrollView, viewport) = (gridScrollView, gridViewport)
        case .panel: (scrollView, viewport) = (panelScrollView, panelViewport)
        }
        guard let scrollView, viewport.height > 0 else { return }

        let band: CGFloat = 72
        let y = session.finger.y
        var speed: CGFloat = 0
        if y < viewport.minY + band {
            speed = -Self.autoscrollSpeed((viewport.minY + band - y) / band)
        } else if y > viewport.maxY - band {
            speed = Self.autoscrollSpeed((y - (viewport.maxY - band)) / band)
        }
        guard speed != 0 else { return }

        let inset = scrollView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let old = scrollView.contentOffset.y
        let new = min(max(old + speed * elapsed, top), bottom)
        guard abs(new - old) > 0.1 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: new), animated: false)
        // The content just moved under a still finger. Shift our copy of the
        // grid's origin now rather than a frame from now, when its
        // `onGeometryChange` gets round to saying so — and the scroll the
        // library grid's labels are placed by, for the same reason.
        switch session.zone {
        case .grid:
            grid.origin.y -= new - old
            grid.labels.scrolled += new - old
        case .panel:
            panel.origin.y -= new - old
        }
        evaluate(immediate: true)
    }

    /// Points a second, by how deep into the band at the edge the finger is:
    /// the same pace as the old loop's 3 + 16t² points a step, sixty steps a
    /// second.
    private static func autoscrollSpeed(_ depth: CGFloat) -> CGFloat {
        let t = min(max(depth, 0), 1.3)
        return 180 + 960 * t * t
    }
}

/// A display link: `tick` once a frame with the seconds since the last, until
/// it returns false or `stop()` is called.
private final class FrameTicker: NSObject {
    private let tick: (CFTimeInterval) -> Bool
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    init(tick: @escaping (CFTimeInterval) -> Bool) {
        self.tick = tick
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Also what breaks the link's hold on this object.
    func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = last.map { link.timestamp - $0 } ?? link.duration
        last = link.timestamp
        // A long stall moves the grid as far as a short one, not in one leap.
        if !tick(min(elapsed, 1.0 / 30.0)) { stop() }
    }
}

/// The order a colour sort replaced. One level deep, and only good until the
/// arrangement changes some other way — a card lifted, an album removed,
/// arranging ended — because restoring it after a hand-made move would undo
/// that move as well, which isn't what "undo the sort" means.
struct ColorSortUndo {
    /// The folder that was sorted, or nil for the library's top level. The
    /// button only offers the undo where the sort happened.
    let folderID: String?
    let restore: () -> Void
}

/// What the card being dragged looks like, drawn by `LiftedItemLayer`.
struct LiftedCard {
    var item: LibraryItem
    /// A folder's albums, for its tile.
    var contents: [Album]
    var size: CGFloat
    var scale: CGFloat = 1
    var opacity: Double = 1
    /// How much of the lift's shadow it casts: all of it in hand, none once
    /// it's down.
    var shadow: Double = 1
}

/// A new folder's first album, drawn back from where it stood into its corner
/// of the tile as the card in hand settles into the next, the plate that
/// formed behind it (`FormingPlate`) thinning away, since a tile has none.
/// Drawn by `LiftedItemLayer` from the drop to the landing.
struct SettlingCover {
    let album: Album
    let size: CGFloat
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
    /// Where the plate gathers to: the tile's middle.
    let plateTo: CGPoint
}

private enum DropCandidate: Equatable {
    case reorder(Int)
    case merge(LibraryItemID)
}

private struct DragSession {
    let item: LibraryItemID
    var zone: LibraryDragZone
    /// The hold carrying the card, which `putDownIfAbandoned` checks on.
    weak var recognizer: UIGestureRecognizer?
    /// Cover centre minus the finger, so the card stays under the finger where
    /// it was picked up rather than jumping to centre itself.
    let grabOffset: CGSize
    var finger: CGPoint
    var gridOrder: [LibraryItemID]
    var panelOrder: [PersistentIdentifier]
    var albums: [PersistentIdentifier: Album]
    var folders: [String: LibraryFolder]
    let context: ModelContext
    let makeFolder: () -> LibraryFolder
    var pending: DropCandidate?

    /// The grid's order into the store: each top-level item's `displayOrder`
    /// is its slot, and an album inside a folder takes its folder's slot (see
    /// `Album.libraryFolderID`). Only writes what changed, so an untouched
    /// album isn't invalidated.
    func writeGridOrder() {
        var folderSlots: [String: Int] = [:]
        for (index, id) in gridOrder.enumerated() {
            switch id {
            case .album(let albumID):
                if let album = albums[albumID], album.displayOrder != index { album.displayOrder = index }
            case .folder(let folderID):
                folderSlots[folderID] = index
                if let folder = folders[folderID], folder.displayOrder != index { folder.displayOrder = index }
            }
        }
        for album in albums.values {
            guard let folderID = album.libraryFolderID, let slot = folderSlots[folderID],
                  album.displayOrder != slot else { continue }
            album.displayOrder = slot
        }
    }

    func writeFolderOrder(_ order: [PersistentIdentifier]) {
        for (index, id) in order.enumerated() {
            if let album = albums[id], album.libraryFolderOrder != index { album.libraryFolderOrder = index }
        }
    }
}

// MARK: - The hold

/// Both ways a hold on the grid rearranges it, on one recognizer.
///
/// **Arranging**, it's an ordinary UIKit long press: hold a card briefly and
/// it lifts, and the recognizer's own `.changed` events carry the drag.
///
/// **Not arranging**, the hold that matters is the one that outlasts the
/// context menu, and no recognizer can see that. The moment the menu's
/// recognizer fires, UIKit has every other recognizer in the hierarchy
/// `ignore` the touch — ours included, however `canBePrevented` and
/// `shouldRecognizeSimultaneously` answer — and shortly afterwards cancels it
/// for the whole window. What it doesn't do is stop updating the `UITouch`:
/// its `phase` reads `.stationary` right through the menu and `.ended` the
/// instant the finger lifts. So this recognizer only uses its delegate's
/// `shouldReceive` to catch the touch as it lands, and the touch itself is
/// watched: still down and still in place at `holdToArrange` means arrange.
///
/// It stops at arranging; the card under the finger isn't carried on into a
/// drag, as the Home Screen's is. That was built and measured, and it can't
/// be made to hold: the touch reports its location only while the menu's
/// container view is alive, and once the dismissed menu takes that view away
/// it reads (0, 0) until the finger lifts. Keeping the menu up, invisibly,
/// to keep the touch readable would leave its rows live under the finger —
/// and lifting over "Remove from Library" would remove the album. Touching
/// the card again, now jiggling, lifts it straight away.
///
/// Attached to the scroll view rather than to each cell, so a drag belongs to
/// something that outlives any one card: a `LazyVGrid` discards cells that
/// scroll away, and a recognizer on a discarded cell cancels its drag.
struct LibraryHoldGesture: UIGestureRecognizerRepresentable {
    /// Watch touches for the hold that starts arranging. Off while arranging.
    var watchesLongHold: Bool
    /// Arranging: whether a hold here may lift a card.
    var shouldBegin: (CGPoint) -> Bool
    /// A hold outlasted the context menu.
    var onLongHold: () -> Void
    /// Where, and the recognizer that will carry the card from there.
    var onBegan: (CGPoint, UIGestureRecognizer) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (_ cancelled: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> HoldRecognizer {
        let recognizer = HoldRecognizer()
        recognizer.minimumPressDuration = LibraryArranger.holdToPickUp
        recognizer.delegate = context.coordinator
        update(context.coordinator)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: HoldRecognizer, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.watchesLongHold = watchesLongHold
        coordinator.shouldBegin = shouldBegin
        coordinator.onLongHold = onLongHold
    }

    func handleUIGestureRecognizerAction(_ recognizer: HoldRecognizer, context: Context) {
        let point = context.converter.location(in: LibraryArranger.coordinateSpace)
        switch recognizer.state {
        case .began: onBegan(point, recognizer)
        case .changed: onChanged(point)
        case .ended: onEnded(false)
        case .cancelled, .failed: onEnded(true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: UIGestureRecognizerRepresentableCoordinateSpaceConverter
        var watchesLongHold = false
        var shouldBegin: (CGPoint) -> Bool = { _ in false }
        var onLongHold: () -> Void = {}
        private var holdWatch: Task<Void, Never>?

        /// How far a finger may drift and still be holding.
        private static let holdSlop: CGFloat = 10

        init(converter: UIGestureRecognizerRepresentableCoordinateSpaceConverter) {
            self.converter = converter
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            shouldBegin(converter.location(in: LibraryArranger.coordinateSpace))
        }

        /// Every touch that lands on the grid passes through here first —
        /// the one moment this recognizer is sure to see it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if watchesLongHold, holdWatch == nil {
                holdWatch = Task { [weak self] in
                    await self?.watch(touch)
                    self?.holdWatch = nil
                }
            }
            return true
        }

        /// Alongside everything except a pan — the cards' buttons and context
        /// menus above all. Not the scroll: whichever of the two claims the
        /// touch first should have it outright, or lifting a card would also
        /// scroll the grid.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            !(other is UIPanGestureRecognizer)
        }

        private func watch(_ touch: UITouch) async {
            let origin = touch.location(in: nil)
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < LibraryArranger.holdToArrange {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, Self.isHeld(touch, near: origin) else { return }
            }
            if watchesLongHold { onLongHold() }
        }

        private static func isHeld(_ touch: UITouch, near origin: CGPoint) -> Bool {
            switch touch.phase {
            case .began, .moved, .stationary:
                // Windowless, a touch reads (0, 0) — not a place, so not a hold.
                guard touch.window != nil else { return false }
                let point = touch.location(in: nil)
                return hypot(point.x - origin.x, point.y - origin.y) <= holdSlop
            default:
                return false
            }
        }
    }
}

/// A long press only a scroll can shut out, so a card lifts even over a
/// button that's also tracking the touch.
final class HoldRecognizer: UILongPressGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        preventing is UIPanGestureRecognizer
    }
}

/// Put away any context menu on screen. A hold that outlasts the menu becomes
/// arrange mode, and the menu has to go with it; there is no SwiftUI handle on
/// a presented `.contextMenu`, so this asks every interaction in the window.
func dismissPresentedContextMenus() {
    func visit(_ view: UIView) {
        for case let menu as UIContextMenuInteraction in view.interactions {
            menu.dismissMenu()
        }
        view.subviews.forEach(visit)
    }
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .forEach(visit)
}

/// Hands over the `UIScrollView` a SwiftUI `ScrollView` is drawn with, for
/// auto-scroll to drive. Place it inside the scroll view's content.
struct EnclosingScrollViewReader: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onResolve = onResolve
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onResolve = onResolve
    }

    final class Probe: UIView {
        var onResolve: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    onResolve?(scrollView)
                    return
                }
                view = current.superview
            }
        }
    }
}

// MARK: - Cells

/// Everything arrange mode does to a card: the jiggle, the delete badge, the
/// hole it leaves when lifted, and the "drop here" response when another card
/// hovers over it. One modifier for albums and folders alike, applied
/// unconditionally so a card's identity is the same in and out of the mode —
/// the hold that starts the mode is still holding this card when it starts.
struct ArrangeChrome: ViewModifier {
    let id: LibraryItemID
    let arranger: LibraryArranger
    let coverSize: CGFloat
    /// Nil for folders: the Home Screen gives folders no delete badge.
    var onRemove: (() -> Void)?

    func body(content: Content) -> some View {
        let arranging = arranger.isArranging
        let isLifted = arranger.draggedItem == id
        let isTarget = arranger.mergeTarget == id
        // An album under a hovering album draws back into a plate that grows
        // behind it: the folder, forming. A folder just swells.
        let targetScale: CGFloat = isTarget ? (id.isFolder ? 1.08 : Self.drawBack) : 1
        content
            // About the cover's centre, not the card's: the label hangs below
            // — or, in the library's grid, mostly doesn't (`LibraryLabelLine`)
            // — so the card's height says nothing about where the cover's
            // middle is. Scaled from the top, where the cover always starts,
            // then let down by what that moved the cover's centre.
            .scaleEffect(targetScale, anchor: .top)
            .offset(y: (1 - targetScale) * coverSize / 2)
            .background(alignment: .top) {
                if !id.isFolder {
                    FormingPlate(coverSize: coverSize)
                        .offset(y: -FormingPlate.margin)
                        .scaleEffect(isTarget ? 1 : 0.8)
                        .opacity(isTarget ? 1 : 0)
                }
            }
            .overlay(alignment: .topLeading) {
                if arranging, !isLifted, let onRemove {
                    RemoveBadge(action: onRemove)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .modifier(Jiggle(isActive: arranging && !isLifted, seed: id.hashValue))
            .opacity(isLifted ? 0 : 1)
    }
}

/// The plate that grows behind an album while another is held over it: the
/// folder, forming. Concentric with the cover, `margin` outside it.
struct FormingPlate: View {
    static let margin: CGFloat = 7
    let coverSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: AlbumArtworkThumbnail.defaultCornerRadius + Self.margin, style: .continuous)
            .fill(Color.white.opacity(0.16))
            .frame(width: coverSize + 2 * Self.margin, height: coverSize + 2 * Self.margin)
    }
}

extension ArrangeChrome {
    /// How far an album draws back while another is held over it to make a
    /// folder; a new folder's first album sets off into its tile from here.
    static let drawBack: CGFloat = 0.86
    /// How far the delete badge hangs off the cover's top-left corner.
    static let badgeOverhang: CGFloat = 9

    /// The outline a card's context menu lifts: the card, grown to take in
    /// the delete badge (see `albumCell`). The extra margin is transparent, so
    /// the ordinary menu looks no different.
    ///
    /// Square-cornered on purpose. A rounded rectangle grown this far grows its
    /// corner radius with it, and the badge sits exactly in the corner that
    /// rounding cuts away — it still lost a sliver of its edge. The margin
    /// clears the badge by a few points more than its circle, for the soft
    /// shadow the glass draws past it and the jiggle tilting it outward.
    static var menuPreviewShape: some InsettableShape {
        Rectangle().inset(by: -(badgeOverhang + 7))
    }
}

/// The edit-mode wobble.
///
/// A `TimelineView` rather than a `repeatForever` animation: a repeating
/// animation is hard to *stop* — flip the flag back and it tends to run on in
/// the old transaction — where a paused timeline simply stops asking. It only
/// ticks while arranging, so the per-frame cost is confined to that mode.
private struct Jiggle: ViewModifier {
    let isActive: Bool
    let seed: Int

    func body(content: Content) -> some View {
        TimelineView(.sixtyHertz(paused: !isActive)) { timeline in
            content.rotationEffect(.degrees(isActive ? angle(at: timeline.date) : 0))
        }
    }

    /// About a degree, a little under four times a second, each card starting
    /// at its own point in the cycle so the grid doesn't wobble in step. The
    /// Home Screen's is closer to two degrees, but on an icon a third this
    /// size; the same swing on a cover is what reads as the same motion.
    private func angle(at date: Date) -> Double {
        let phase = Double(UInt(bitPattern: seed) % 628) / 100
        return 1.1 * sin(date.timeIntervalSinceReferenceDate * 2 * .pi * 3.7 + phase)
    }
}

/// Liquid Glass, like the toolbar's buttons: it floats over the cover, and
/// real glass takes on whatever art is under it where a flat grey disc read as
/// a sticker. No `GlassRim` — the glass brings its own edge.
///
/// UIKit's glass (`GlassDisc`), not SwiftUI's `glassEffect`. The badge rides
/// its card's jiggle, and SwiftUI works a glass effect out again on every
/// frame it moves — the shape's bounds, its container's, the material — which
/// across a screen of jiggling badges was a third of everything arranging
/// cost the main thread, before a card was even picked up. Holding the badges
/// still made that cost vanish, and made them look stuck on rather than
/// attached. A `UIVisualEffectView` that a transform moves is a layer moving:
/// the glass is the render server's business.
private struct RemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.ui(12, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background { GlassDisc() }
                // A finger's worth of target around a small mark.
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(BadgePress())
        .offset(x: -ArrangeChrome.badgeOverhang, y: -ArrangeChrome.badgeOverhang)
        .accessibilityLabel("Remove from Library")
    }

    /// The give that interactive glass has under a finger. UIKit's only shows
    /// it to touches that reach the glass itself, and here the button takes
    /// them.
    private struct BadgePress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .animation(.snappy(duration: 0.18), value: configuration.isPressed)
        }
    }
}

/// A circle of Liquid Glass, drawn by UIKit — see `RemoveBadge` for why.
private struct GlassDisc: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.isUserInteractionEnabled = false
        view.cornerConfiguration = .capsule()
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

/// A folder's face: its first four covers, two by two, filling a cover's
/// square — no plate under them. Two by two rather than the Home Screen's
/// three by three: an app icon survives shrinking to a ninth of a tile, and
/// album art — detail, type, photographs — doesn't.
///
/// It sat on a pale glass plate, with the covers inset from its rim, until
/// 2026-10-12, when the plate came off at the user's ask: the four covers now
/// reach the tile's edges, so their outline is exactly a cover's and a
/// folder stands among albums at their size.
struct FolderTile: View {
    let albums: [Album]
    let size: CGFloat
    /// Covers waiting for the card settling onto them (`LibraryArranger
    /// .arrivingAlbums`): shown the moment it lands, exactly under it.
    var hidden: Set<PersistentIdentifier> = []

    /// A cover's, since the tile stands among covers in for one.
    static let cornerRadius: CGFloat = AlbumArtworkThumbnail.defaultCornerRadius
    private static let perSide = 2
    /// How many covers a tile shows.
    static let capacity = perSide * perSide

    /// Where the `index`th cover sits on a tile `size` across. Worked out
    /// rather than left to a grid, because an opening folder flies each one
    /// from exactly here to its place in the panel (`FolderZoom`).
    ///
    /// Out to the tile's edges. On a tile in the grid the gap between its
    /// covers is the library's own gutter, the same distance as between full
    /// covers (2026-10-28, at the user's ask; it was scaled to the minis, ~7pt).
    /// A tile too small for that — a list row's — keeps a gap scaled to it.
    /// The covers take whatever's left, unrounded; their corners stay the
    /// covers' own 3¼pt either way.
    static func miniFrame(_ index: Int, size: CGFloat) -> CGRect {
        let gap = size >= 100 ? LibraryView.gridGutter : max(2, (size * 0.04).rounded())
        let mini = (size - gap * CGFloat(perSide - 1)) / CGFloat(perSide)
        return CGRect(
            x: CGFloat(index % perSide) * (mini + gap),
            y: CGFloat(index / perSide) * (mini + gap),
            width: mini,
            height: mini
        )
    }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            // The whole square answers a tap, gaps included.
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                ForEach(Array(albums.prefix(Self.capacity).enumerated()), id: \.element.id) { index, album in
                    let frame = Self.miniFrame(index, size: size)
                    // Rimmed like every cover in the library, so the ones in a
                    // folder read as the same objects, set down in it.
                    AlbumArtworkThumbnail(
                        album: album,
                        size: frame.width,
                        cornerRadius: AlbumArtworkThumbnail.defaultCornerRadius
                    )
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(hidden.contains(album.persistentModelID) ? 0 : 1)
                }
            }
    }
}

/// A folder in the library grid: the tile, and a label block cut exactly like
/// `AlbumCard`'s, so a row of both lines up and `LibraryGridGeometry` holds.
struct FolderCard: View {
    let folder: LibraryFolder
    let albums: [Album]
    var coverSize: CGFloat
    /// As `AlbumCard.row`: the card's row in the library's grid, nil where the
    /// label simply stays.
    var row: Int? = nil
    /// The folder is open, and its layer is drawing the tile — growing out of
    /// this spot, or shrinking back into it. The label stays, as on the Home
    /// Screen: only the icon lifts off.
    var tileHidden = false
    /// Covers on the tile still waiting for their cards (`FolderTile.hidden`).
    var arriving: Set<PersistentIdentifier> = []

    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 album" : "\(count) albums"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderTile(albums: albums, size: coverSize, hidden: arriving)
                .opacity(tileHidden ? 0 : 1)
                // Gone the instant the folder's layer covers it, never faded.
                // The press style animates the whole card as it springs back
                // from the tap, and faded under that, the tile lingered
                // behind the opening folder as a second copy of it.
                .animation(nil, value: tileHidden)
            LibraryCardLabel(row: row) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name)
                        .font(.uiSubheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fadingTruncation()
                    Text(Self.countLabel(albums.count))
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .fadingTruncation()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: AlbumCard.labelHeight, alignment: .top)
                .padding(.horizontal, 4)
            }
        }
        .frame(width: coverSize)
        // As `AlbumCard`'s: the label is hidden on most rows of the grid.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([folder.name, Self.countLabel(albums.count)].joined(separator: ", "))
        .contentShape(.accessibility, Rectangle())
    }
}

// MARK: - Opening a folder

/// How an open folder moves, both ways, and the panel it becomes.
///
/// One spring carries the folder — the plate, and everything on it — and the
/// rest are timed against where that spring is: it covers half its distance
/// in its first tenth of a second and most of the rest by a quarter, so the
/// crossfades sit early, the settling late.
enum FolderMotion {
    /// The whole choreography's clock. Every duration and delay here is the
    /// one it was tuned at, run at this pace, so a change of speed leaves the
    /// hand-overs where they are against the spring — slip one of those and
    /// covers cross-fade over nothing. 0.7 since 2026-10-28, at the user's
    /// ask ("speed up the animation"); it was 1.
    private static let pace: TimeInterval = 0.7
    private static func t(_ seconds: TimeInterval) -> TimeInterval { seconds * pace }

    private static let openDuration = t(0.42)
    private static let closeDuration = t(0.36)

    /// A breath of overshoot opening, as the Home Screen's folders have, and
    /// none closing — a tile that overshoots its own slot reads as a bounce.
    static let open: Animation = .spring(duration: openDuration, bounce: 0.12)
    static let close: Animation = .spring(duration: closeDuration)

    /// The blur keeps its own time rather than riding the spring. A spring
    /// covers most of its distance in its first tenth of a second, and a
    /// blur reads as done long before it is — on the spring, the library
    /// looked blurred the instant the folder was tapped. Eased in, it starts
    /// on the tap and deepens across the whole opening, done as the folder
    /// settles; closing runs it backwards, so the library comes sharp just
    /// as the folder lands — and before the layer comes down, which it would
    /// otherwise cut short.
    static let blurIn: Animation = .easeIn(duration: openDuration)
    static let blurOut: Animation = .easeOut(duration: closeDuration - t(0.04))

    /// The tile's covers onto the panel's first four, well before the plate
    /// arrives — they have to be over the panel's own covers by the time
    /// those fade up under them. Closing, they wait for the panel to go first.
    static let coversIn: Animation = .spring(duration: t(0.24))
    static let coversOut: Animation = .spring(duration: t(0.26)).delay(t(0.07))
    /// The panel — labels, any further covers — under the arrived covers;
    /// closing, gone before they leave.
    static let panelIn: Animation = .easeInOut(duration: t(0.06)).delay(t(0.11))
    static let panelOut: Animation = .easeInOut(duration: t(0.05)).delay(t(0.02))
    /// The travelling covers off, over identical covers; closing, on at once.
    static let coversOff: Animation = .easeInOut(duration: t(0.05)).delay(t(0.17))
    static let coversOn: Animation = .easeOut(duration: t(0.03))
    /// A travelling cover's hairline: gone as it leaves the tile, and closing,
    /// back over the last of its trip, as `coversOut` sets it down.
    static let edgeOff: Animation = .easeOut(duration: t(0.06))
    static let edgeOn: Animation = .easeIn(duration: t(0.08)).delay(t(0.25))
    static let titleIn: Animation = .easeOut(duration: t(0.22)).delay(t(0.12))
    static let titleOut: Animation = .easeIn(duration: t(0.1))
    /// The panel's titles and artists: up once the covers are in place,
    /// and closing, gone first — the close waits `labelsOutLead` for them,
    /// since the panel itself vanishes as soon as the spring starts.
    static let labelsIn: Animation = .easeOut(duration: t(0.3)).delay(t(0.18))
    static let labelsOut: Animation = .easeIn(duration: t(0.12))
    static let labelsOutLead = t(0.1)
    /// From asking a folder to close to its layer being down: the labels'
    /// lead, then the spring.
    static var closeTotal: TimeInterval { labelsOutLead + closeDuration }

    static let plateRadius: CGFloat = 30
    static let dim: CGFloat = 0.35
    /// The name sits in a band this tall above the panel, bottom-aligned, so
    /// the panel's place never waits on measuring a line of text.
    static let titleBand: CGFloat = 60
    static let titleGap: CGFloat = 18
}

/// An open folder, grown out of its tile the way the Home Screen's are: the
/// plate stretches from the tile's frame to the panel's, the tile's covers
/// grow into the panel's first four, and the library behind blurs across
/// the whole opening. Closing runs it all back into the tile.
///
/// It mounts collapsed — pixel for pixel the tile it covers, which
/// `FolderCard.tileHidden` has just taken away — and only starts growing on
/// the next turn of the run loop. The frame that builds the panel's grid is
/// then one on which nothing moves; building it and starting the animation
/// on the same frame is what made opening a folder stutter.
struct FolderZoom<Title: View, Panel: View>: View {
    let arranger: LibraryArranger
    /// The tile's frame, in this view's space. Nil when it isn't on screen to
    /// grow out of, and the folder fades up where it opens instead.
    let tile: CGRect?
    /// The panel's frame once open, in this view's space.
    let panelFrame: CGRect
    /// The panel's grid, in the panel's own space, unscrolled.
    let panelGrid: LibraryGridGeometry
    let albums: [Album]
    let onClose: () -> Void
    @ViewBuilder let title: Title
    @ViewBuilder let panel: Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = arranger.isFolderExpanded
        let hiddenForDrag = arranger.folderHiddenForDrag
        let depth: CGFloat = expanded && !hiddenForDrag ? 1 : 0
        FolderZoomStage(
            expanded: expanded,
            labelsShown: arranger.areFolderLabelsShown,
            // Reduce Motion: fade up in place rather than fly out of the
            // tile. A tile not yet laid out has nothing to grow out of.
            tile: reduceMotion ? nil : tile.flatMap { $0.width >= 1 ? $0 : nil },
            panelFrame: panelFrame,
            panelGrid: panelGrid,
            albums: albums,
            title: title,
            panel: panel
        )
        // Dragged out of, the folder fades, and the library comes back into
        // focus under the card; the layer stays up until the drop.
        .opacity(hiddenForDrag ? 0 : 1)
        // Behind, not beside: the backdrop reaches under the bars, and as a
        // sibling it stretched the stack the stage is laid out in — the
        // panel's frame, and the tile's, came out a bar's height off.
        .background {
            ZStack {
                FolderBackdrop(depth: depth)
                    .animation(depth > 0 ? FolderMotion.blurIn : FolderMotion.blurOut, value: depth)
                    .allowsHitTesting(false)
                // Tapping the library closes the folder, arranging or not.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(!hiddenForDrag)
        .task {
            // Still while it grows: see `MotionShine.isHeld`. Let go once it
            // has settled — unless it was closed again on the way, and the
            // close lets go instead.
            MotionShine.shared.isHeld = true
            withAnimation(FolderMotion.open) {
                arranger.isFolderExpanded = true
            } completion: {
                if arranger.isFolderExpanded { MotionShine.shared.isHeld = false }
            }
            withAnimation(FolderMotion.labelsIn) { arranger.areFolderLabelsShown = true }
        }
        // However the layer comes down — dragged out of, emptied — the rims
        // aren't left holding still.
        .onDisappear { MotionShine.shared.isHeld = false }
    }
}

/// `FolderZoom`'s drawing, as two poses — the tile and the open panel — that
/// SwiftUI moves between on its own.
///
/// Everything that moves is a transform, an opacity or an animatable shape,
/// so a frame of the animation is SwiftUI interpolating numbers: this body
/// runs once per open or close, not once per frame, and nothing is laid out
/// or drawn again on the way. That is the whole point. The first version
/// recomputed this stage every frame, and resized a `GlassRim` on every one
/// of them — whose lobe is an angular gradient the CPU rasterises, most of
/// the main thread's time in the profile — and it read as choppy however
/// right each frame was. The plate and its rims are gone now (2026-10-12),
/// and nothing that changes size draws anything but the clip.
///
/// Opening, in order: the tile's covers slide and grow onto where the
/// panel's first four will be; the panel — labels, any further covers —
/// comes up under them; then they go, over covers now identical to them.
/// Nothing is ever crossfaded against something in a different place.
private struct FolderZoomStage<Title: View, Panel: View>: View {
    let expanded: Bool
    let labelsShown: Bool
    let tile: CGRect?
    let panelFrame: CGRect
    let panelGrid: LibraryGridGeometry
    let albums: [Album]
    let title: Title
    let panel: Panel

    var body: some View {
        let target = panelFrame
        // With no tile to come from: the panel, a little smaller, in place.
        let source = tile ?? target.insetBy(dx: target.width * 0.08, dy: target.height * 0.08)
        let plate = expanded ? target : source
        // The panel scales to the plate's width; its height is the clip's.
        // Both ends are linear in the spring, so scale and plate move as one.
        let scale = plate.width / target.width
        let radius = expanded || tile == nil ? FolderMotion.plateRadius : FolderTile.cornerRadius
        let shape = PlateShape(rect: plate, cornerRadius: radius)
        let lift = (FolderMotion.titleBand + FolderMotion.titleGap) * scale
        // The plate is drawn by nothing — no fill, edge or glass, at either
        // end (2026-10-12, at the user's ask): the covers sit straight on the
        // blurred library, as they sit on the library itself. The shape is
        // still the panel's clip, which is what grows it out of the tile.
        ZStack(alignment: .topLeading) {
            panel
                // A hundredth rather than zero while hidden, for the reason
                // the panel's own fade gives below.
                .environment(\.folderLabelOpacity, labelsShown ? 1 : 0.01)
                // The covers' hairlines come and go with the words: away while
                // the panel is still growing or about to shrink, so no 1pt line
                // is being scaled on them (`coverEdgeOpacity`).
                .environment(\.coverEdgeOpacity, labelsShown ? 1 : 0.01)
                .frame(width: target.width, height: target.height)
                // Never quite zero, like the backdrop's blur: at zero neither
                // is drawn, and their first draw then lands on the spring's
                // first frames — the panel's every card at once, the blur's
                // whole backdrop pass. A hundredth over, both are drawn as the
                // layer goes up, while nothing is moving yet.
                .opacity(expanded ? 1 : 0.01)
                .animation(expanded ? FolderMotion.panelIn : FolderMotion.panelOut, value: expanded)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: plate.minX, y: plate.minY)
                // The whole stage, so the clip below is in the stage's space —
                // the same shape, on the same spring, as the plate itself.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(shape)

            title
                .frame(width: target.width, height: FolderMotion.titleBand, alignment: .bottom)
                .opacity(expanded ? 1 : 0)
                .animation(expanded ? FolderMotion.titleIn : FolderMotion.titleOut, value: expanded)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: plate.minX, y: plate.minY - lift)

            if let tile {
                travellingCovers(tile: tile)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: plate.minX, y: plate.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The tile's covers, each on its way from its place on the tile to its
    /// place in the panel — in the panel's own space, so they ride its
    /// transform and only their own short trip is theirs. Drawn at the
    /// tile's size and scaled, so they are the thumbnails the tile already
    /// had: nothing to fetch, and nothing redrawn, mid-flight.
    private func travellingCovers(tile: CGRect) -> some View {
        // Where the panel is drawn at the tile: this scale, this origin. A
        // mini's place on the tile, taken back through that, is where it
        // starts in the panel's space.
        let startScale = target.width > 0 ? tile.width / target.width : 1
        return ZStack(alignment: .topLeading) {
            ForEach(Array(albums.prefix(FolderTile.capacity).enumerated()), id: \.element.id) { index, album in
                let mini = FolderTile.miniFrame(index, size: tile.width)
                let center = panelGrid.coverCenter(of: index)
                let cover = panelGrid.cover
                AlbumArtworkThumbnail(
                    album: album,
                    size: mini.width,
                    cornerRadius: AlbumArtworkThumbnail.defaultCornerRadius
                )
                // The tile's own covers have a hairline, so these do at either
                // end and none on the way: off as they lift off the tile, back
                // as they land on it.
                .environment(\.coverEdgeOpacity, expanded ? 0.01 : 1)
                .animation(expanded ? FolderMotion.edgeOff : FolderMotion.edgeOn, value: expanded)
                .scaleEffect(expanded ? cover / mini.width : 1 / startScale, anchor: .topLeading)
                .offset(
                    x: expanded ? center.x - cover / 2 : mini.minX / startScale,
                    y: expanded ? center.y - cover / 2 : mini.minY / startScale
                )
                .animation(expanded ? FolderMotion.coversIn : FolderMotion.coversOut, value: expanded)
            }
        }
        .opacity(expanded ? 0 : 1)
        .animation(expanded ? FolderMotion.coversOff : FolderMotion.coversOn, value: expanded)
    }

    private var target: CGRect { panelFrame }
}

/// A rounded rectangle anywhere in its frame, animatable as one: the open
/// folder's plate, its clip and its hairline all draw this, so on one spring
/// they cannot drift apart.
private nonisolated struct PlateShape: InsettableShape {
    var rect: CGRect
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(rect.animatableData, cornerRadius) }
        set {
            rect.animatableData = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        Path(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, cornerRadius - inset),
            style: .continuous
        )
    }

    func inset(by amount: CGFloat) -> PlateShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// The library behind an open folder, blurred and dimmed to `depth`. An
/// animatable depth, so the blur is scrubbed frame by frame on whatever curve
/// it's given (`FolderMotion.blurIn`/`blurOut`), through any reversal.
private struct FolderBackdrop: View, Animatable {
    var depth: CGFloat

    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    var body: some View {
        // A hundredth, never none, while the layer is up: see the panel's
        // opacity in `FolderZoomStage`. Invisible, and it primes the blur.
        ScrubbedBlur(fraction: min(max(depth, 0.01), 1))
    }
}

/// A blur that can stand anywhere between none and full.
///
/// UIKit, because only there does a blur *deepen*: a SwiftUI material is on
/// or off — fading one in reads as a sharp library dissolving into a blurred
/// one — and `.blur(radius:)` on the library would re-render every cover
/// through the filter each frame. A `UIVisualEffectView` animated from no
/// effect to a blur passes through every radius between; paused, it can be
/// scrubbed to any of them.
///
/// Scrubbed rather than *played*: SwiftUI updates a representable with
/// animations disabled, so a `UIView` animation started from here never runs
/// — the blur landed all at once, a frame before the folder began to move.
private struct ScrubbedBlur: UIViewRepresentable {
    let fraction: CGFloat

    final class Coordinator {
        weak var view: UIVisualEffectView?
        weak var dim: UIView?
        var animator: UIViewPropertyAnimator?
        var fraction: CGFloat = 0
        var observer: NSObjectProtocol?

        /// A paused animator from no blur to full, set at `fraction`.
        ///
        /// Made afresh on each return to the foreground and each return to
        /// the window — back from an album opened out of the folder: both
        /// strip a paused animation from its layer, leaving the view at the
        /// end state and the animator scrubbing nothing, and a folder closed
        /// after that would stay fully blurred until it was gone.
        func rebuild() {
            // Made where UIKit has animations switched off — as SwiftUI has
            // them while it puts a view into the window — an animator isn't
            // one: its block simply runs, the view sits at full blur, and the
            // scrub moves nothing. The folder then opened onto a library
            // already blurred. Wait a turn, until they're back on.
            guard UIView.areAnimationsEnabled else {
                Task { @MainActor [weak self] in self?.rebuild() }
                return
            }
            guard let view else { return }
            animator?.stopAnimation(true)
            view.effect = nil
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
                view.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            }
            animator.pausesOnCompletion = true
            animator.pauseAnimation()
            animator.fractionComplete = fraction
            self.animator = animator
        }

        func scrub(to fraction: CGFloat) {
            self.fraction = fraction
            animator?.fractionComplete = fraction
            dim?.alpha = fraction
        }

        /// An animator must be stopped before it's released, or UIKit throws.
        func tearDown() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            animator?.stopAnimation(true)
            animator = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class BlurView: UIVisualEffectView {
        var onEnterWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterWindow?() }
        }
    }

    func makeUIView(context: Context) -> BlurView {
        let view = BlurView(effect: nil)
        view.isUserInteractionEnabled = false
        let dim = UIView(frame: view.contentView.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = .black.withAlphaComponent(FolderMotion.dim)
        dim.alpha = 0
        view.contentView.addSubview(dim)

        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.dim = dim
        coordinator.rebuild()
        view.onEnterWindow = { [weak coordinator] in coordinator?.rebuild() }
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.rebuild() }
        }
        return view
    }

    func updateUIView(_ view: BlurView, context: Context) {
        context.coordinator.scrub(to: fraction)
    }

    static func dismantleUIView(_ view: BlurView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
}

/// The card in hand, drawn above everything — the grid, the open folder and
/// its dimming — so it can travel between them, and under it a new folder's
/// first album on its way into the tile. The only reader of
/// `LibraryArranger.liftPoint`.
struct LiftedItemLayer: View {
    let arranger: LibraryArranger

    var body: some View {
        ZStack {
            if let settling = arranger.settling {
                SettlingCoverView(cover: settling)
            }
            if let lifted = arranger.lifted {
                Group {
                    switch lifted.item {
                    case .album(let album):
                        AlbumArtworkThumbnail(album: album, size: lifted.size)
                    case .folder:
                        FolderTile(albums: lifted.contents, size: lifted.size)
                    }
                }
                .scaleEffect(lifted.scale)
                .shadow(color: .black.opacity(0.5 * lifted.shadow), radius: 18, y: 10)
                .opacity(lifted.opacity)
                .position(arranger.liftPoint)
            }
        }
        .allowsHitTesting(false)
    }
}

/// `SettlingCover` on its way, on the drop's spring, begun as it first draws:
/// put up and sent off in the same update it would have no first frame to
/// move from, and would simply be at its corner.
private struct SettlingCoverView: View {
    let cover: SettlingCover
    @State private var settled = false

    var body: some View {
        ZStack {
            FormingPlate(coverSize: cover.size)
                .scaleEffect(settled ? cover.size / (cover.size + 2 * FormingPlate.margin) : 1)
                .opacity(settled ? 0 : 1)
                .position(settled ? cover.plateTo : cover.from)
            AlbumArtworkThumbnail(album: cover.album, size: cover.size)
                .scaleEffect(settled ? cover.toScale : cover.fromScale)
                .position(settled ? cover.to : cover.from)
        }
        .onAppear {
            withAnimation(LibraryArranger.settle) { settled = true }
        }
    }
}

