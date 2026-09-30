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
/// that. Every card is the same size — a cover plus `AlbumCard.labelBlock` —
/// so a slot is arithmetic on the grid's origin, and the origin is the one
/// thing measured (`onGeometryChange`, into the arranger's coordinate space).
struct LibraryGridGeometry {
    var origin: CGPoint = .zero
    var columns = 2
    var cover: CGFloat = 150
    var columnSpacing: CGFloat = 30
    var rowSpacing: CGFloat = 16

    private var pitch: CGSize {
        CGSize(width: cover + columnSpacing, height: cover + AlbumCard.labelBlock + rowSpacing)
    }

    /// The card under `point`, if any. Gutters hit nothing, so a hold between
    /// two covers is left to the scroll view.
    func itemIndex(at point: CGPoint, count: Int) -> Int? {
        let x = point.x - origin.x, y = point.y - origin.y
        guard x >= 0, y >= 0, columns > 0 else { return nil }
        let column = Int(x / pitch.width), row = Int(y / pitch.height)
        guard column < columns,
              x - CGFloat(column) * pitch.width <= cover,
              y - CGFloat(row) * pitch.height <= cover + AlbumCard.labelBlock
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
        let column = min(max(Int(floor((x + (pitch.width - cover) / 2) / pitch.width)), 0), columns - 1)
        let row = max(Int(floor((y + (pitch.height - cover) / 2) / pitch.height)), 0)
        let raw = row * columns + column
        var over: Int?
        if raw < count {
            let coverRect = CGRect(
                x: CGFloat(column) * pitch.width, y: CGFloat(row) * pitch.height,
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
            x: origin.x + CGFloat(index % columns) * pitch.width + cover / 2,
            y: origin.y + CGFloat(index / columns) * pitch.height + cover / 2
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
    /// A pause, for the dwell: the finger staying within this of where it was.
    private static let pauseSlop: CGFloat = 8

    // MARK: Observed — each changes a few times a drag at most

    var isArranging = false
    /// The folder whose layer is up. Setting it puts the layer up *collapsed*,
    /// exactly over the folder's tile; `isFolderExpanded` is what grows it.
    var openFolderID: String?
    /// The open folder is open, as opposed to growing out of its tile or
    /// shrinking back into it. Read by `FolderZoom` alone — anything in
    /// `LibraryView.body` keyed on it would re-run the library on the
    /// spring's first frame. False whenever `openFolderID` is nil.
    var isFolderExpanded = false
    /// The open folder has faded because its album was dragged out, but stays
    /// in the hierarchy until the drop: the recognizer carrying the drag is
    /// attached to it, and removing the view would cancel the drag.
    var folderHiddenForDrag = false
    var draggedItem: LibraryItemID?
    var mergeTarget: LibraryItemID?
    var lifted: LiftedCard?
    /// "Sort by Color" is reading covers. Nothing may be picked up, opened or
    /// closed meanwhile — it's about to renumber everything on screen.
    var isSortingByColor = false
    /// What the last colour sort overwrote, while it can still be put back.
    var colorSortUndo: ColorSortUndo?

    // MARK: Observed per frame — read by `LiftedItemLayer` and nothing else

    var liftPoint: CGPoint = .zero

    // MARK: Not observed

    @ObservationIgnored var grid = LibraryGridGeometry()
    @ObservationIgnored var panel = LibraryGridGeometry()
    @ObservationIgnored var gridViewport: CGRect = .zero
    @ObservationIgnored var panelViewport: CGRect = .zero
    /// Where each folder's tile is in list layout, which has no arithmetic to
    /// work it out from — measured, for an open folder to grow out of.
    @ObservationIgnored var rowTileFrames: [String: CGRect] = [:]
    @ObservationIgnored weak var gridScrollView: UIScrollView?
    @ObservationIgnored weak var panelScrollView: UIScrollView?
    @ObservationIgnored private var session: DragSession?
    @ObservationIgnored private var isSettling = false
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    /// Where the finger was when the current dwell started. Moving further
    /// than `pauseSlop` from it starts the dwell over.
    @ObservationIgnored private var dwellAnchor: CGPoint = .zero
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    @ObservationIgnored private var autoscrollTask: Task<Void, Never>?

    /// A card is in hand or still flying home, or a colour sort is under way.
    /// Nothing else may start then.
    var isBusy: Bool { session != nil || isSettling || isSortingByColor }

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

        liftPoint = center
        lifted = LiftedCard(item: card, contents: contents, size: geometry.cover)
        draggedItem = card.id
        withAnimation(.snappy(duration: 0.22)) { lifted?.scale = 1.1 }
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
            withAnimation(.snappy(duration: 0.2)) { self.mergeTarget = nil }
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
            withAnimation(.snappy(duration: 0.22)) { mergeTarget = target }
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
        autoscrollTask?.cancel()
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
        isSettling = true

        let destination: CGPoint
        var absorbed = false
        var createdFolderID: String?

        if !cancelled, session.zone == .grid, let target = mergeTarget,
           let landing = merge(into: target, session: &session, createdFolderID: &createdFolderID) {
            withAnimation(Self.reflow) { session.writeGridOrder() }
            destination = grid.coverCenter(of: session.gridOrder.firstIndex(of: landing) ?? 0)
            absorbed = true
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
        // Into a folder: shrink away inside the tile.
        let closesFolder = folderHiddenForDrag
        let newFolderID = createdFolderID
        withAnimation(.snappy(duration: 0.3)) {
            liftPoint = destination
            lifted?.scale = absorbed ? 0.35 : 1
            lifted?.opacity = absorbed ? 0 : 1
            mergeTarget = nil
        } completion: { [weak self] in
            guard let self else { return }
            draggedItem = nil
            lifted = nil
            isSettling = false
            if closesFolder {
                openFolderID = nil
                isFolderExpanded = false
                folderHiddenForDrag = false
            }
            // A new folder opens on arrival, as on the Home Screen — the name
            // is right there to change. It grows out of the tile the card just
            // shrank into.
            if let newFolderID { openFolderID = newFolderID }
        }
    }

    /// Drop the dragged album onto `target`: into it if it's a folder, into a
    /// new folder with it if it's an album. Returns what the card should fly
    /// into, or nil if the merge can't happen and this is an ordinary drop.
    private func merge(
        into target: LibraryItemID,
        session: inout DragSession,
        createdFolderID: inout String?
    ) -> LibraryItemID? {
        guard case .album(let draggedID) = session.item, let dragged = session.albums[draggedID] else { return nil }
        let draggedItem = session.item
        switch target {
        case .folder(let folderID):
            let count = session.albums.values.filter { $0.libraryFolderID == folderID }.count
            dragged.libraryFolderID = folderID
            dragged.libraryFolderOrder = count
            session.gridOrder.removeAll { $0 == draggedItem }
            return target
        case .album(let targetID):
            guard let targetAlbum = session.albums[targetID],
                  let slot = session.gridOrder.firstIndex(of: target) else { return nil }
            let folder = session.makeFolder()
            session.context.insert(folder)
            session.folders[folder.folderID] = folder
            targetAlbum.libraryFolderID = folder.folderID
            targetAlbum.libraryFolderOrder = 0
            dragged.libraryFolderID = folder.folderID
            dragged.libraryFolderOrder = 1
            // The folder takes the target's place; the dragged album's hole closes.
            session.gridOrder[slot] = .folder(folder.folderID)
            session.gridOrder.removeAll { $0 == draggedItem }
            createdFolderID = folder.folderID
            return .folder(folder.folderID)
        }
    }

    // MARK: Auto-scroll

    /// Held near the top or bottom of whichever grid the card is in, the grid
    /// scrolls — faster the closer to the edge. A loop rather than a reaction
    /// to movement, because the whole point is a finger holding still.
    ///
    /// The scroll view is driven directly (`EnclosingScrollViewReader` found
    /// it) rather than through a SwiftUI `ScrollPosition`, which would be a
    /// state change on `LibraryView` every frame of the scroll.
    private func startAutoscroll() {
        autoscrollTask?.cancel()
        autoscrollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.session != nil else { return }
                self.autoscrollTick()
            }
        }
    }

    private func autoscrollTick() {
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
        let new = min(max(old + speed, top), bottom)
        guard abs(new - old) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: new), animated: false)
        // The content just moved under a still finger. Shift our copy of the
        // grid's origin now rather than a frame from now, when its
        // `onGeometryChange` gets round to saying so.
        switch session.zone {
        case .grid: grid.origin.y -= new - old
        case .panel: panel.origin.y -= new - old
        }
        evaluate(immediate: true)
    }

    private static func autoscrollSpeed(_ depth: CGFloat) -> CGFloat {
        let t = min(max(depth, 0), 1.3)
        return 3 + 16 * t * t
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
}

private enum DropCandidate: Equatable {
    case reorder(Int)
    case merge(LibraryItemID)
}

private struct DragSession {
    let item: LibraryItemID
    var zone: LibraryDragZone
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
    var onBegan: (CGPoint) -> Void
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
        case .began: onBegan(point)
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
        // Scale about the cover's centre, not the card's — the label hangs below.
        let coverAnchor = UnitPoint(x: 0.5, y: coverSize / 2 / (coverSize + AlbumCard.labelBlock))
        content
            // An album under a hovering album draws back into a plate that
            // grows behind it: the folder, forming. A folder just swells.
            .scaleEffect(isTarget ? (id.isFolder ? 1.08 : 0.86) : 1, anchor: coverAnchor)
            .background(alignment: .top) {
                if !id.isFolder {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: coverSize + 14, height: coverSize + 14)
                        .offset(y: -7)
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

extension ArrangeChrome {
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
        TimelineView(.animation(paused: !isActive)) { timeline in
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
private struct RemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.ui(12, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: .circle)
                // A finger's worth of target around a small mark.
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .offset(x: -ArrangeChrome.badgeOverhang, y: -ArrangeChrome.badgeOverhang)
        .accessibilityLabel("Remove from Library")
    }
}

/// A folder's face: its first four covers, two by two, on a pale plate shaped
/// like a cover. Two by two rather than the Home Screen's three by three: an
/// app icon survives shrinking to a ninth of a tile, and album art — detail,
/// type, photographs — doesn't.
struct FolderTile: View {
    let albums: [Album]
    let size: CGFloat

    static let cornerRadius: CGFloat = 12
    static let plateOpacity: Double = 0.09
    private static let perSide = 2
    /// How many covers a tile shows.
    static let capacity = perSide * perSide
    /// `GlassRim`'s hairline, which the margins are measured inside of.
    private static let rimWidth: CGFloat = 1

    /// Where the `index`th cover sits on a tile `size` across. Worked out
    /// rather than left to a grid, because an opening folder flies each one
    /// from exactly here to its place in the panel (`FolderZoom`).
    ///
    /// One spacing for everything: the plate's edge to a cover, and one cover
    /// to the next, so the covers sit on an even grid rather than a tight
    /// cluster in a wide frame. "The edge" is the rim, which is drawn *inside*
    /// the plate — measured from the plate's bounds instead, the margins came
    /// out a rim's width narrower than the gaps, and the eye measures from the
    /// line it can see. The covers take whatever's left, unrounded, so no
    /// remainder drifts back into the margins.
    static func miniFrame(_ index: Int, size: CGFloat) -> CGRect {
        let gap = max(2, (size * 0.08).rounded())
        let inset = rimWidth + gap
        let mini = (size - gap * CGFloat(perSide + 1) - rimWidth * 2) / CGFloat(perSide)
        return CGRect(
            x: inset + CGFloat(index % perSide) * (mini + gap),
            y: inset + CGFloat(index / perSide) * (mini + gap),
            width: mini,
            height: mini
        )
    }

    /// A cover's rounding, shrunk with it so a small cover isn't a lozenge.
    static func miniCornerRadius(_ mini: CGFloat) -> CGFloat {
        max(2, mini * 0.12)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(Self.plateOpacity))
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) {
                ForEach(Array(albums.prefix(Self.capacity).enumerated()), id: \.element.id) { index, album in
                    let frame = Self.miniFrame(index, size: size)
                    // Rimmed like every cover in the library, so the ones in a
                    // folder read as the same objects, set down in it.
                    AlbumArtworkThumbnail(
                        album: album,
                        size: frame.width,
                        cornerRadius: Self.miniCornerRadius(frame.width)
                    )
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
            .overlay(GlassRim(cornerRadius: Self.cornerRadius, lineWidth: Self.rimWidth))
    }
}

/// A folder in the library grid: the tile, and a label block cut exactly like
/// `AlbumCard`'s, so a row of both lines up and `LibraryGridGeometry` holds.
struct FolderCard: View {
    let folder: LibraryFolder
    let albums: [Album]
    var coverSize: CGFloat
    /// The folder is open, and its layer is drawing the tile — growing out of
    /// this spot, or shrinking back into it. The label stays, as on the Home
    /// Screen: only the icon lifts off.
    var tileHidden = false

    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 album" : "\(count) albums"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AlbumCard.labelSpacing) {
            FolderTile(albums: albums, size: coverSize)
                .opacity(tileHidden ? 0 : 1)
                // Gone the instant the folder's layer covers it, never faded.
                // The press style animates the whole card as it springs back
                // from the tap, and faded under that, the tile lingered
                // behind the opening folder as a second copy of it.
                .animation(nil, value: tileHidden)
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
        .frame(width: coverSize)
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
    private static let openDuration: TimeInterval = 0.42
    private static let closeDuration: TimeInterval = 0.36

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
    static let blurOut: Animation = .easeOut(duration: closeDuration - 0.04)

    /// The tile's covers onto the panel's first four, well before the plate
    /// arrives — they have to be over the panel's own covers by the time
    /// those fade up under them. Closing, they wait for the panel to go first.
    static let coversIn: Animation = .spring(duration: 0.24)
    static let coversOut: Animation = .spring(duration: 0.26).delay(0.07)
    /// The panel — labels, any further covers — under the arrived covers;
    /// closing, gone before they leave.
    static let panelIn: Animation = .easeInOut(duration: 0.06).delay(0.11)
    static let panelOut: Animation = .easeInOut(duration: 0.05).delay(0.02)
    /// The travelling covers off, over identical covers; closing, on at once.
    static let coversOff: Animation = .easeInOut(duration: 0.05).delay(0.17)
    static let coversOn: Animation = .easeOut(duration: 0.03)
    static let titleIn: Animation = .easeOut(duration: 0.22).delay(0.12)
    static let titleOut: Animation = .easeIn(duration: 0.1)
    /// The glass lobes at each end — see `FolderZoomStage`.
    static let tileLobeOff: Animation = .easeOut(duration: 0.05)
    static let tileLobeOn: Animation = .easeIn(duration: 0.08).delay(0.26)
    static let panelLobeOn: Animation = .easeIn(duration: 0.15).delay(0.2)
    static let panelLobeOff: Animation = .easeOut(duration: 0.06)

    static let plateRadius: CGFloat = 30
    static let plateOpacity = 0.08
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
/// right each frame was. So the rims here never change size: the plate's
/// moving edge is a plain hairline on the animated shape, and its glass lobe
/// is two fixed rims, one at the tile and one at the panel, crossfaded.
///
/// Opening, in order: the tile's covers slide and grow onto where the
/// panel's first four will be; the panel — labels, any further covers —
/// comes up under them; then they go, over covers now identical to them.
/// Nothing is ever crossfaded against something in a different place.
private struct FolderZoomStage<Title: View, Panel: View>: View {
    let expanded: Bool
    let tile: CGRect?
    let panelFrame: CGRect
    let panelGrid: LibraryGridGeometry
    let albums: [Album]
    let title: Title
    let panel: Panel

    @Environment(\.colorScheme) private var scheme

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
        // With no tile, the plate and all on it simply fade up.
        let plateOpacity: Double = tile == nil && !expanded ? 0 : 1

        ZStack(alignment: .topLeading) {
            shape
                .fill(Color.white.opacity(expanded || tile == nil ? FolderMotion.plateOpacity : FolderTile.plateOpacity))
                .opacity(plateOpacity)

            panel
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

            // The plate's edge. The hairline rides the shape; the lobe is
            // fixed at each end and crossfaded, because a rim that changes
            // size is re-rasterised on every frame it does.
            shape
                .strokeBorder(GlassRim<RoundedRectangle>.hairline(scheme), lineWidth: 1)
                .opacity(plateOpacity)
                .allowsHitTesting(false)
            if let tile {
                GlassRim(cornerRadius: FolderTile.cornerRadius, showsBase: false)
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY)
                    .opacity(expanded ? 0 : 1)
                    .animation(expanded ? FolderMotion.tileLobeOff : FolderMotion.tileLobeOn, value: expanded)
            }
            GlassRim(cornerRadius: FolderMotion.plateRadius, showsBase: false)
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .opacity(expanded ? 1 : 0.01)
                .animation(expanded ? FolderMotion.panelLobeOn : FolderMotion.panelLobeOff, value: expanded)

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
                    cornerRadius: FolderTile.miniCornerRadius(mini.width)
                )
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
/// its dimming — so it can travel between them. The only reader of
/// `LibraryArranger.liftPoint`.
struct LiftedItemLayer: View {
    let arranger: LibraryArranger

    var body: some View {
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
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .opacity(lifted.opacity)
            .position(arranger.liftPoint)
            .allowsHitTesting(false)
        }
    }
}

