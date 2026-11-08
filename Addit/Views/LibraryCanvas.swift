import SwiftData
import SwiftUI
import UIKit

// MARK: - Layouts

/// How the library lays out its albums: picked from the layout menu right of
/// the orb, or in Settings. Stored by name under `storageKey`.
enum LibraryLayout: String, CaseIterable, Identifiable {
    /// Labelled covers two across, and what arranging uses whatever's picked.
    case grid
    case list
    /// Every cover on one field that pans every way (`LibraryCanvas`).
    case canvas

    var id: Self { self }

    static let storageKey = "libraryLayout"

    var title: String {
        switch self {
        case .grid: "Icons"
        case .list: "List"
        case .canvas: "Canvas"
        }
    }

    /// In the menu, and on the layout button for the layout in use.
    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .canvas: "square.grid.3x3"
        }
    }

    /// Moves the old grid-or-list switch, a Bool under `libraryViewMode`, to
    /// `storageKey`, so a library left on List stays on it. At launch, before
    /// anything reads either.
    static func migrateStoredSetting(in defaults: UserDefaults = .standard) {
        let legacy = "libraryViewMode"
        guard defaults.object(forKey: legacy) != nil else { return }
        if defaults.string(forKey: storageKey) == nil {
            defaults.set((defaults.bool(forKey: legacy) ? list : grid).rawValue, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacy)
    }
}

// MARK: - Canvas

/// An ask to bring an album on screen in the canvas; `request` changes with
/// each ask.
struct CanvasReveal: Equatable {
    let album: PersistentIdentifier
    let request: Int
}

/// Each cover's `CoverTone`, measured once a session for as long as its art
/// stays the same. The library keeps it, not the canvas, so coming back to
/// the canvas doesn't measure the whole library again. Unobserved on
/// purpose: the canvas reads it when its albums change, and a write is no
/// reason to draw.
final class CoverToneCache {
    private var tones: [String: CoverTone?] = [:]

    func contains(_ key: String) -> Bool { tones.index(forKey: key) != nil }
    func tone(_ key: String) -> CoverTone? { tones[key] ?? nil }
    func record(_ tone: CoverTone?, for key: String) { tones.updateValue(tone, forKey: key) }
}

/// The library as one round field of covers you pan around, after Cosmos's
/// canvas: three across, the grid's gutter between them and its corner on
/// each (`AlbumArtworkThumbnail.defaultCornerRadius`, not scaled down with
/// the covers), and no labels. Every cover once, on a disc sorted by colour
/// both ways (`ColorSort.canvas`), and past its edges the scroll view's own
/// elastic pull. It ran on for ever, mirrored, until 2026-10-28.
///
/// Nothing is drawn until every cover has been measured, the first time
/// through; after that the tones are the library's (`CoverToneCache`).
struct LibraryCanvas<Tile: View>: View {
    let albums: [Album]
    let tones: CoverToneCache
    /// Measures covers the cache hasn't seen, in order.
    let measure: @MainActor ([Album]) async -> [CoverTone?]
    /// The toolbar ornaments' offset, which the pan up and down feeds.
    let offset: ScrollOffsetBox
    let reveal: CanvasReveal?
    let tile: (Album, CGFloat) -> Tile

    init(
        albums: [Album],
        tones: CoverToneCache,
        measure: @escaping @MainActor ([Album]) async -> [CoverTone?],
        offset: ScrollOffsetBox,
        reveal: CanvasReveal?,
        @ViewBuilder tile: @escaping (Album, CGFloat) -> Tile
    ) {
        self.albums = albums
        self.tones = tones
        self.measure = measure
        self.offset = offset
        self.reveal = reveal
        self.tile = tile
    }

    @Environment(AlbumArtService.self) private var albumArtService

    @State private var grid: CanvasDisc?
    /// The albums `grid` was sorted from, which its cells index.
    @State private var placed: [Album] = []
    /// The reveal already asked for when the canvas came up: not its to answer.
    @State private var answered: Int?

    var body: some View {
        ZStack {
            if let grid, !placed.isEmpty {
                CanvasField(grid: grid, albums: placed, offset: offset, reveal: placedReveal, tile: tile)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { answered = reveal?.request }
        .task(id: albums.map(albumKey)) { await arrange() }
    }

    /// A reveal whose album is on the field. One just added gets there only
    /// once its cover's been measured, so the ask waits for it.
    private var placedReveal: CanvasReveal? {
        guard let reveal, reveal.request != answered,
              placed.contains(where: { $0.persistentModelID == reveal.album })
        else { return nil }
        return reveal
    }

    /// Measures what the cache hasn't seen, sorts, and puts the new grid up.
    private func arrange() async {
        let albums = albums
        let keys = albums.map(coverKey)
        let missing = albums.indices.filter { !tones.contains(keys[$0]) }
        if !missing.isEmpty {
            let measured = await measure(missing.map { albums[$0] })
            // Kept even if this sort's been overtaken: they're true either way.
            for (index, tone) in zip(missing, measured) {
                tones.record(tone, for: keys[index])
            }
            guard !Task.isCancelled else { return }
        }
        let next = ColorSort.canvas(tones: keys.map(tones.tone))
        #if DEBUG
        print("[Canvas] \(albums.count) covers (\(missing.count) measured) → \(next.rows) rows × \(next.columns) columns, \(next.cells.count - albums.count) doubled")
        #endif
        withAnimation(.easeInOut(duration: 0.3)) {
            grid = next
            placed = albums
        }
    }

    /// What a tone measures: the art, as `AlbumArtworkThumbnail.artworkTaskID`
    /// names it, less the size it's drawn at.
    private func coverKey(_ album: Album) -> String {
        let refresh = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refresh)-\(album.localCoverPath ?? "")"
    }

    private func albumKey(_ album: Album) -> String {
        "\(album.googleFolderId)|\(coverKey(album))"
    }
}

/// The field: a scroll view over the disc, which opens centred and bounces
/// past every edge, building only the covers on screen and one row and
/// column more all round (`CanvasWindow`).
private struct CanvasField<Tile: View>: View {
    let grid: CanvasDisc
    let albums: [Album]
    let offset: ScrollOffsetBox
    let reveal: CanvasReveal?
    let tile: (Album, CGFloat) -> Tile

    /// Nil until the scroll view first says where it is; everything, then.
    @State private var window: CanvasWindow?
    @State private var scroller = CanvasScroller()

    var body: some View {
        GeometryReader { proxy in
            if let metrics = CanvasMetrics(size: proxy.size, gutter: LibraryView.gridGutter, grid: grid) {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(cells(metrics)) { cell in
                            tile(albums[cell.item], metrics.cover)
                                .position(cell.center)
                        }
                    }
                    .frame(width: metrics.width, height: metrics.height, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        EnclosingScrollViewReader { scrollView in
                            scroller.scrollView = scrollView
                            if let album = scroller.pendingReveal {
                                scroller.pendingReveal = nil
                                DispatchQueue.main.async { bringIntoView(album, metrics) }
                            }
                        }
                        .frame(width: 1, height: 1)
                    }
                    // A disc smaller than the screen sits in its middle.
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .defaultScrollAnchor(.center)
                .scrollBounceBehavior(.always, axes: [.horizontal, .vertical])
                .onScrollGeometryChange(for: CanvasGeometry.self) { geometry in
                    CanvasGeometry(geometry, viewport: proxy.size, metrics: metrics)
                } action: { _, geometry in
                    if !scroller.hasOpened, geometry.contentWidth >= metrics.width - 1,
                       let scrollView = scroller.scrollView {
                        scroller.hasOpened = true
                        openBetweenColumns(scrollView, geometry, metrics)
                    }
                    let next = metrics.window(showing: geometry.visible)
                    if next != window { window = next }
                    offset.follow(geometry.offsetY)
                    if offset.top != -geometry.insetTop { offset.top = -geometry.insetTop }
                }
                .onChange(of: reveal, initial: true) { _, reveal in
                    if let reveal { bringIntoView(reveal.album, metrics) }
                }
            }
        }
    }

    private func cells(_ metrics: CanvasMetrics) -> [CanvasCell] {
        let window = window ?? CanvasWindow(rows: 0...max(grid.rows - 1, 0), columns: 0...max(grid.columns - 1, 0))
        var cells: [CanvasCell] = []
        for row in window.rows {
            for column in window.columns {
                guard let item = grid.item(row: row, column: column) else { continue }
                cells.append(CanvasCell(
                    id: albums[item].persistentModelID,
                    item: item,
                    center: metrics.center(row: row, column: column)
                ))
            }
        }
        return cells
    }

    /// The opening position, moved sideways so the screen's middle falls on
    /// the gap between two columns rather than down a cover (2026-10-28, at
    /// the user's ask): a column cut off at each edge says the field goes on
    /// sideways too. Centred on the disc, an odd number of columns put one
    /// square in the middle with the screen's edges on gutters, which read as
    /// a grid that only scrolls down. Only when the disc is wider than the
    /// screen; a narrower one sits in its middle.
    private func openBetweenColumns(_ scrollView: UIScrollView, _ geometry: CanvasGeometry, _ metrics: CanvasMetrics) {
        let width = geometry.visible.width
        guard metrics.width > width else { return }
        let middle = geometry.visible.midX
        let gap = metrics.gutter / 2
        let nearest = ((middle - gap) / metrics.pitch).rounded(.toNearestOrAwayFromZero) * metrics.pitch + gap
        var x = scrollView.contentOffset.x + nearest - middle
        x = min(max(x, 0), scrollView.contentSize.width - width)
        scrollView.contentOffset.x = x
    }

    /// Scrolls `album`'s cover to the middle of what's between the bars.
    private func bringIntoView(_ album: PersistentIdentifier, _ metrics: CanvasMetrics) {
        guard let scrollView = scroller.scrollView else {
            scroller.pendingReveal = album
            return
        }
        guard let item = albums.firstIndex(where: { $0.persistentModelID == album }),
              let cell = grid.cells.firstIndex(of: item) else { return }
        let target = metrics.center(row: cell / grid.columns, column: cell % grid.columns)
        // The content is the disc's frame, centred in one at least a screen
        // big: where the disc's top-left sits in it.
        let content = scrollView.contentSize
        let origin = CGPoint(x: max(0, (content.width - metrics.width) / 2),
                             y: max(0, (content.height - metrics.height) / 2))
        let insets = scrollView.adjustedContentInset
        let size = scrollView.bounds.size
        let visible = CGSize(width: size.width, height: size.height - insets.top - insets.bottom)
        var point = CGPoint(x: origin.x + target.x - visible.width / 2,
                            y: origin.y + target.y - visible.height / 2 - insets.top)
        point.x = min(max(point.x, -insets.left), max(-insets.left, content.width + insets.right - size.width))
        point.y = min(max(point.y, -insets.top), max(-insets.top, content.height + insets.bottom - size.height))
        scrollView.setContentOffset(point, animated: true)
    }
}

/// The field's arithmetic: where a cell is, and which a view touches.
struct CanvasMetrics: Equatable {
    let cover: CGFloat
    let gutter: CGFloat
    let rows: Int
    let columns: Int

    var pitch: CGFloat { cover + gutter }
    var width: CGFloat { gutter + CGFloat(columns) * pitch }
    var height: CGFloat { gutter + CGFloat(rows) * pitch }

    /// Nil for a layout pass that hasn't been given its width yet, which
    /// `LibraryView.gridLayout(for:)` refuses for the same reason.
    init?(size: CGSize, gutter: CGFloat, grid: CanvasDisc) {
        // Three across, the gutter at both edges and between.
        let cover = (size.width - 4 * gutter) / 3
        guard cover >= 44, grid.rows > 0, grid.columns > 0 else { return nil }
        self.cover = cover
        self.gutter = gutter
        rows = grid.rows
        columns = grid.columns
    }

    func center(row: Int, column: Int) -> CGPoint {
        CGPoint(
            x: gutter + CGFloat(column) * pitch + cover / 2,
            y: gutter + CGFloat(row) * pitch + cover / 2
        )
    }

    /// The cells `visible`, a rect of the disc's own frame, touches, and one
    /// more all round.
    func window(showing visible: CGRect) -> CanvasWindow {
        func span(_ low: CGFloat, _ high: CGFloat, _ count: Int) -> ClosedRange<Int> {
            let first = Int(((low - gutter) / pitch).rounded(.down)) - 1
            let last = Int(((high - gutter) / pitch).rounded(.down)) + 1
            let lower = min(max(first, 0), count - 1)
            return lower...min(max(last, lower), count - 1)
        }
        return CanvasWindow(
            rows: span(visible.minY, visible.maxY, rows),
            columns: span(visible.minX, visible.maxX, columns)
        )
    }
}

/// A block of the disc's cells, rows and columns.
struct CanvasWindow: Equatable {
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>
}

private struct CanvasCell: Identifiable {
    let id: PersistentIdentifier
    let item: Int
    let center: CGPoint
}

/// The field's hold on its `UIScrollView`, for Add Existing's "take me to
/// it". A reference that's never observed.
private final class CanvasScroller {
    weak var scrollView: UIScrollView?
    /// An album asked for before the scroll view was found.
    var pendingReveal: PersistentIdentifier?
    /// The opening position has been set (`openBetweenColumns`).
    var hasOpened = false
}

/// What the field reads off its scroll view: what's on screen, in the disc's
/// own frame — the scroll view's whole height, under the bars too, since all
/// of it shows covers — and the numbers the ornaments follow.
private struct CanvasGeometry: Equatable {
    var visible: CGRect
    var offsetY: CGFloat
    var insetTop: CGFloat
    var contentWidth: CGFloat

    init(_ geometry: ScrollGeometry, viewport: CGSize, metrics: CanvasMetrics) {
        let insets = geometry.contentInsets
        let content = geometry.contentSize
        // The disc's frame sits centred in content at least the viewport big.
        let origin = CGPoint(x: max(0, (content.width - metrics.width) / 2),
                             y: max(0, (content.height - metrics.height) / 2))
        visible = CGRect(
            x: geometry.contentOffset.x - origin.x,
            y: geometry.contentOffset.y - origin.y,
            width: geometry.containerSize.width + insets.leading + insets.trailing,
            height: geometry.containerSize.height + insets.top + insets.bottom
        )
        offsetY = geometry.contentOffset.y
        insetTop = insets.top
        contentWidth = content.width
    }
}
