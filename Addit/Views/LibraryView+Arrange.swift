import SwiftUI
import SwiftData
import UIKit

/// Folders and arrange mode — the library as a Home Screen. The drag itself
/// lives in `LibraryArranger` (`LibraryArrange.swift`); this is the half that
/// knows about the library: what's in it, what a card looks like, and what a
/// hold means before and after arranging starts.
extension LibraryView {
    // MARK: - What's where

    /// The library on screen, as the grid draws it.
    ///
    /// The top level is loose albums and non-empty folders in one sequence by
    /// `displayOrder`. Sorted here rather than trusting `@Query`'s order,
    /// because arranging rewrites `displayOrder` live and the grid has to
    /// follow on the same frame, not on the next fetch. An album naming a
    /// folder this library doesn't have — one pruned, or left over from
    /// another library — is simply loose.
    func libraryArrangement() -> LibraryArrangement {
        let inLibrary = currentLibraryFilter()
        let libraryFolders = folders.filter(currentFolderFilter())
        let folderIDs = Set(libraryFolders.map(\.folderID))

        var loose: [Album] = []
        var contents: [String: [Album]] = [:]
        for album in albums where inLibrary(album) {
            if let folderID = album.libraryFolderID, folderIDs.contains(folderID) {
                contents[folderID, default: []].append(album)
            } else {
                loose.append(album)
            }
        }
        for (folderID, list) in contents {
            contents[folderID] = list.enumerated()
                .sorted { ($0.element.libraryFolderOrder, $0.offset) < ($1.element.libraryFolderOrder, $1.offset) }
                .map(\.element)
        }

        // An empty folder isn't shown; it's pruned once nothing can be holding it.
        var keyed: [(order: Int, rank: Int, item: LibraryItem)] = []
        for folder in libraryFolders where contents[folder.folderID] != nil {
            keyed.append((folder.displayOrder, 0, .folder(folder)))
        }
        for album in loose {
            keyed.append((album.displayOrder, 1, .album(album)))
        }
        let items = keyed.enumerated()
            .sorted { ($0.element.order, $0.element.rank, $0.offset) < ($1.element.order, $1.element.rank, $1.offset) }
            .map(\.element.item)
        return LibraryArrangement(items: items, contents: contents)
    }

    /// `currentLibraryFilter`, for folders: they belong to libraries exactly
    /// the way albums do.
    func currentFolderFilter() -> (LibraryFolder) -> Bool {
        let source = currentSource
        let accountId = activeAccountId
        return { folder in
            source == .localStorage
                ? folder.storageSource == .localStorage
                : folder.storageSource == source && folder.accountId == accountId
        }
    }

    /// How many albums the open folder holds; -1 with none open.
    func openFolderAlbumCount(_ arrangement: LibraryArrangement) -> Int {
        guard let folderID = arranger.openFolderID else { return -1 }
        return arrangement.contents[folderID]?.count ?? 0
    }

    // MARK: - Arrange mode

    func beginArranging() {
        guard !arranger.isArranging else { return }
        // Arranging is the whole library, never a search's slice of it.
        if isSearchExpanded || !searchText.isEmpty {
            searchText = ""
            isSearchFocused = false
            withAnimation(.easeInOut(duration: 0.25)) { isSearchExpanded = false }
        }
        withAnimation(.snappy(duration: 0.25)) { arranger.isArranging = true }
    }

    func endArranging() {
        guard arranger.isArranging, !arranger.isBusy else { return }
        arranger.colorSortUndo = nil
        withAnimation(.snappy(duration: 0.25)) { arranger.isArranging = false }
        pruneEmptyFolders()
        try? modelContext.save()
    }

    /// Delete folders nothing is filed in.
    ///
    /// Never done the moment a folder empties: that happens mid-drag, when the
    /// open folder's view (hidden, carrying the drag) and the lifted card can
    /// both still be reading it, and a deleted model read after a save traps.
    /// Here nothing is in hand, and the open folder is spared regardless.
    func pruneEmptyFolders() {
        guard !arranger.isBusy else { return }
        let occupied = Set(albums.compactMap(\.libraryFolderID))
        let empty = folders.filter {
            !occupied.contains($0.folderID) && $0.folderID != arranger.openFolderID
        }
        guard !empty.isEmpty else { return }
        empty.forEach(modelContext.delete)
        try? modelContext.save()
    }

    /// "Folder 1", "Folder 2"… — the first not already taken in this library.
    /// Deliberately plain; renaming is one tap on the open folder's title.
    func nextFolderName() -> String {
        let taken = Set(folders.filter(currentFolderFilter()).map(\.name))
        let number = (1...).first { !taken.contains("Folder \($0)") } ?? 1
        return "Folder \(number)"
    }

    // MARK: - Sort by colour

    /// Lay out what's on screen as a rainbow (`ColorSort`): the open folder if
    /// there is one, otherwise the library's loose albums — folders keep their
    /// places at the top, since a folder has no one colour to sort by.
    func sortByColor() {
        guard arranger.isArranging, !arranger.isBusy else { return }
        let arrangement = libraryArrangement()
        let folderID = arranger.openFolderID
        var pinned: [LibraryFolder] = []
        let albums: [Album]
        if let folderID {
            albums = arrangement.contents[folderID] ?? []
        } else {
            albums = arrangement.items.compactMap {
                if case .album(let album) = $0 { return album }
                if case .folder(let folder) = $0 { pinned.append(folder) }
                return nil
            }
        }
        guard albums.count > 1 else { return }
        let columns = folderID == nil ? arranger.grid.columns : arranger.panel.columns

        arranger.isSortingByColor = true
        Task {
            let tones = await coverTones(for: albums)
            let order = ColorSort.order(tones: tones, columns: columns, firstColumn: pinned.count)
            let undo = ColorSortUndo(
                folderID: folderID,
                restore: orderRestorer(folderID: folderID, albums: albums, pinned: pinned, arrangement: arrangement)
            )
            withAnimation(.snappy(duration: 0.6)) {
                if folderID != nil {
                    for (position, index) in order.enumerated() {
                        albums[index].libraryFolderOrder = position
                    }
                } else {
                    for (position, folder) in pinned.enumerated() {
                        folder.displayOrder = position
                        // Foldered albums sit where their folder sits.
                        for album in arrangement.contents[folder.folderID] ?? [] {
                            album.displayOrder = position
                        }
                    }
                    for (position, index) in order.enumerated() {
                        albums[index].displayOrder = pinned.count + position
                    }
                }
            }
            try? modelContext.save()
            arranger.colorSortUndo = undo
            arranger.isSortingByColor = false
        }
    }

    /// Put back the order the last colour sort replaced, with the same shuffle.
    func undoColorSort() {
        guard let undo = arranger.colorSortUndo, !arranger.isBusy else { return }
        arranger.colorSortUndo = nil
        withAnimation(.snappy(duration: 0.6)) { undo.restore() }
        try? modelContext.save()
    }

    // MARK: - Disband

    /// The open folder put away and its albums set loose in the library, in
    /// the folder's own place and in its order. It closes into its tile
    /// first, so what it shrinks into is still there; then the tile gives way
    /// to its albums and the grid after it makes room.
    func disbandOpenFolder() {
        guard let folderID = arranger.openFolderID, !arranger.isBusy else { return }
        closeFolder()
        disband(folderID, after: FolderMotion.closeTotal + 0.05, tries: 5)
    }

    /// Once the layer is down — the close ends on its spring's completion,
    /// which can run a little behind the clock.
    private func disband(_ folderID: String, after delay: TimeInterval, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if arranger.openFolderID == folderID {
                if tries > 0 { disband(folderID, after: 0.1, tries: tries - 1) }
                return
            }
            guard arranger.openFolderID == nil, !arranger.isBusy,
                  let folder = folders.first(where: { $0.folderID == folderID }) else { return }
            let arrangement = libraryArrangement()
            arranger.colorSortUndo = nil
            withAnimation(.snappy(duration: 0.35)) {
                var slot = 0
                for item in arrangement.items {
                    switch item {
                    case .album(let album):
                        album.displayOrder = slot
                        slot += 1
                    case .folder(let other) where other.folderID == folderID:
                        for album in arrangement.contents[folderID] ?? [] {
                            album.libraryFolderID = nil
                            album.displayOrder = slot
                            slot += 1
                        }
                    case .folder(let other):
                        other.displayOrder = slot
                        // Foldered albums sit where their folder sits.
                        for album in arrangement.contents[other.folderID] ?? [] {
                            album.displayOrder = slot
                        }
                        slot += 1
                    }
                }
                modelContext.delete(folder)
            }
            try? modelContext.save()
        }
    }

    /// A closure that writes back, exactly, every order value `sortByColor` is
    /// about to overwrite: one folder's `libraryFolderOrder`s, or the top
    /// level's `displayOrder`s — pinned folders, loose albums, and the albums
    /// inside folders, whose `displayOrder` mirrors their folder's slot.
    private func orderRestorer(
        folderID: String?,
        albums: [Album],
        pinned: [LibraryFolder],
        arrangement: LibraryArrangement
    ) -> () -> Void {
        if folderID != nil {
            let before = albums.map { ($0, $0.libraryFolderOrder) }
            return {
                for (album, order) in before where !album.isDeleted { album.libraryFolderOrder = order }
            }
        }
        let foldered = pinned.flatMap { arrangement.contents[$0.folderID] ?? [] }
        let albumsBefore = (albums + foldered).map { ($0, $0.displayOrder) }
        let foldersBefore = pinned.map { ($0, $0.displayOrder) }
        return {
            for (album, order) in albumsBefore where !album.isDeleted { album.displayOrder = order }
            for (folder, order) in foldersBefore where !folder.isDeleted { folder.displayOrder = order }
        }
    }

    /// Each album's `CoverTone`, in order; nil for one with no art to read.
    ///
    /// Covers come through the art service's thumbnail path at a small size —
    /// the same files the grid already decoded, so normally no network — and
    /// are measured together off the main thread.
    func coverTones(for albums: [Album]) async -> [CoverTone?] {
        var images: [UIImage?] = []
        images.reserveCapacity(albums.count)
        for album in albums {
            if album.isLocal {
                if let path = album.resolvedLocalCoverPath {
                    images.append(await albumArtService.thumbnail(atPath: path, pixelSize: 64))
                } else {
                    images.append(nil)
                }
            } else if let fileId = album.coverFileId {
                images.append(await albumArtService.thumbnail(for: fileId, pixelSize: 64))
            } else {
                images.append(nil)
            }
        }
        let snapshot = images
        return await Task.detached(priority: .userInitiated) {
            snapshot.map { $0?.cgImage.flatMap(CoverTone.measure) }
        }.value
    }

    // MARK: - The hold

    /// The hold for one grid: before arranging, the long one — past the
    /// context menu — that starts it; once arranging, the short one that lifts
    /// a card. See `LibraryHoldGesture` for why those are one recognizer.
    func holdGesture(for zone: LibraryDragZone, count: Int) -> LibraryHoldGesture {
        let arranger = arranger
        return LibraryHoldGesture(
            watchesLongHold: !arranger.isArranging,
            shouldBegin: { point in
                // Only a card can be held; anything else is the scroll view's.
                // And not out of a folder on its way back into its tile: the
                // layer comes down as it lands, recognizer and all, with the
                // card still in hand.
                arranger.isArranging && !arranger.isBusy
                    && (zone == .grid || (arranger.isFolderExpanded && arranger.areFolderLabelsShown))
                    && arranger.hasCard(at: point, in: zone, count: count)
            },
            onLongHold: { startArrangingFromHold() },
            onBegan: { point, recognizer in pickUp(at: point, in: zone, carriedBy: recognizer) },
            onChanged: { point in arranger.drag(to: point) },
            onEnded: { cancelled in arranger.drop(cancelled: cancelled) }
        )
    }

    /// The list layout's hold, which only ever starts arranging.
    func listHoldGesture() -> LibraryHoldGesture {
        LibraryHoldGesture(
            watchesLongHold: !arranger.isArranging,
            shouldBegin: { _ in false },
            onLongHold: { startArrangingFromHold() },
            onBegan: { _, _ in },
            onChanged: { _ in },
            onEnded: { _ in }
        )
    }

    /// A hold outlasted the context menu — or landed on empty space and held,
    /// as holding the wallpaper does. Put the menu away and arrange.
    private func startArrangingFromHold() {
        guard !arranger.isArranging, !arranger.isBusy else { return }
        dismissPresentedContextMenus()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        beginArranging()
    }

    private func pickUp(at point: CGPoint, in zone: LibraryDragZone, carriedBy recognizer: UIGestureRecognizer) {
        // What a new folder would be called and where it would live, decided
        // now, while this view's state is the current state.
        let name = nextFolderName()
        let source = currentSource
        let accountId = source.isCloud ? activeAccountId : nil
        arranger.pickUp(
            at: point,
            in: zone,
            carriedBy: recognizer,
            arrangement: libraryArrangement(),
            context: modelContext,
            makeFolder: {
                LibraryFolder(name: name, displayOrder: 0, storageSource: source, accountId: accountId)
            }
        )
    }

    // MARK: - Cards

    /// `row` is the card's row in the library's grid, whose labels come and go
    /// with the scroll; nil in an open folder, whose labels stay.
    @ViewBuilder
    func albumCell(_ album: Album, coverSize: CGFloat, row: Int? = nil) -> some View {
        // A `Button`, not a `NavigationLink`: the link swallows the press
        // state, so a custom `ButtonStyle` renders nothing on it. Pushing the
        // path by hand is what the context menu's Edit already does.
        Button {
            // Arranging, a tap on an album does nothing — the Home Screen
            // doesn't launch apps from edit mode either.
            guard !arranger.isArranging else { return }
            libraryPath.append(.album(album))
        } label: {
            AlbumCard(album: album, coverSize: coverSize, row: row)
        }
        .buttonStyle(ImprintButtonStyle())
        // The chrome goes *inside* the context menu, and the menu's preview
        // shape reaches past the card. Both are for the hold that turns into
        // arranging: the menu floats a live copy of what it's attached to over
        // the card — the real one hidden underneath — and a dismissed menu
        // keeps that copy up until the finger lifts. With the chrome outside,
        // the copy had no badge and sat over the real card's; inside, the copy
        // is the arranged card, and the wider shape stops it being clipped to
        // the card's edge, which cut off the badge where it overhangs.
        .modifier(ArrangeChrome(
            id: .album(album.persistentModelID),
            arranger: arranger,
            coverSize: coverSize,
            onRemove: { albumPendingRemoval = album }
        ))
        .contentShape(.contextMenuPreview, ArrangeChrome.menuPreviewShape)
        // Emptied rather than removed while arranging: the modifier stays, so
        // the card keeps its identity through the switch into arranging.
        .contextMenu {
            if !arranger.isArranging { albumMenu(album) }
        }
    }

    @ViewBuilder
    func folderCell(_ folder: LibraryFolder, albums: [Album], coverSize: CGFloat, row: Int? = nil) -> some View {
        Button {
            openFolder(folder)
        } label: {
            FolderCard(
                folder: folder,
                albums: albums,
                coverSize: coverSize,
                row: row,
                tileHidden: isTileLifted(folder),
                arriving: arranger.arrivingAlbums
            )
        }
        .buttonStyle(ImprintButtonStyle())
        // Inside the context menu, as on `albumCell`.
        .modifier(ArrangeChrome(
            id: .folder(folder.folderID),
            arranger: arranger,
            coverSize: coverSize,
            onRemove: nil
        ))
        .contextMenu {
            if !arranger.isArranging { folderMenu(folder) }
        }
    }

    /// A cover on the canvas: opens its album as a grid card does, with the
    /// same menu, but no label and nothing to arrange. The canvas sorts
    /// itself; Arrange in the menu takes you to the grid to do it there.
    func canvasCell(_ album: Album, coverSize: CGFloat) -> some View {
        Button {
            libraryPath.append(.album(album))
        } label: {
            AlbumArtworkThumbnail(album: album, size: coverSize)
        }
        .buttonStyle(ImprintButtonStyle())
        .contentShape(.contextMenuPreview, RoundedRectangle(
            cornerRadius: AlbumArtworkThumbnail.defaultCornerRadius, style: .continuous
        ))
        .contextMenu { albumMenu(album) }
        .accessibilityLabel(album.name)
    }

    /// Cover and text, nothing else: no chevron, no separator. A `Button`
    /// pushing the route, as a grid card's does. It was a
    /// `NavigationLink(value: album)`, which drew the chevron and, once the
    /// path became `LibraryRoute`s (build 12), matched no destination, so a
    /// tap on a row did nothing.
    func albumRow(_ album: Album) -> some View {
        Button {
            libraryPath.append(.album(album))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkThumbnail(album: album, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.uiBody.weight(.medium))
                        .foregroundStyle(.primary)
                        .fadingTruncation()
                    Text(album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? album.artistName! : "Unknown Artist")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .fadingTruncation()
                }
            }
            .contentShape(Rectangle())
        }
        .contextMenu { albumMenu(album) }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    func folderRow(_ folder: LibraryFolder, albums: [Album]) -> some View {
        Button {
            openFolder(folder)
        } label: {
            HStack(spacing: 12) {
                FolderTile(albums: albums, size: 48)
                    .opacity(isTileLifted(folder) ? 0 : 1)
                    .animation(nil, value: isTileLifted(folder))
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: LibraryArranger.coordinateSpace)
                    } action: { frame in
                        arranger.rowTileFrames[folder.folderID] = frame
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.uiBody.weight(.medium))
                        .foregroundStyle(.primary)
                        .fadingTruncation()
                    Text(FolderCard.countLabel(albums.count))
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .fadingTruncation()
                }
            }
            .contentShape(Rectangle())
        }
        .contextMenu { folderMenu(folder) }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    func albumMenu(_ album: Album) -> some View {
        Button {
            // Here, not in `openForEditing`, which creating and importing
            // call too — only a tap on Edit pops.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openForEditing(album)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button {
            beginArranging()
        } label: {
            Label("Arrange", systemImage: "arrow.up.arrow.down")
        }
        Button("Remove from Library", role: .destructive) {
            // Was a bare `modelContext.delete`, which stranded every file the
            // album owned — an orphan the size of the album, every time.
            removeAlbum(album)
        }
    }

    @ViewBuilder
    func folderMenu(_ folder: LibraryFolder) -> some View {
        Button {
            rename(folder)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            beginArranging()
        } label: {
            Label("Arrange", systemImage: "arrow.up.arrow.down")
        }
    }

    func removalMessage(for album: Album) -> String {
        album.isLocal
            ? "The album and its audio will be deleted from Addit."
            : "It stays in \(album.isOneDrive ? "OneDrive" : "Google Drive") — this only takes it out of Addit."
    }

    // MARK: - Folders

    /// Puts the folder's layer up collapsed over its tile; `FolderZoom` grows
    /// it open from there. Not while another is still shrinking home.
    func openFolder(_ folder: LibraryFolder) {
        guard !arranger.isBusy, arranger.openFolderID == nil else { return }
        arranger.openFolderID = folder.folderID
    }

    /// Shrinks the open folder back into its tile, and only then takes the
    /// layer down — at which point it exactly covers the tile it hands back to.
    func closeFolder() {
        guard arranger.isFolderExpanded, arranger.areFolderLabelsShown, !arranger.isBusy else { return }
        let arranger = arranger
        // The covers fly home from the panel's first row; a scrolled panel
        // is brought back to it as it goes.
        if let scrollView = arranger.panelScrollView {
            let top = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
            if scrollView.contentOffset != top { scrollView.setContentOffset(top, animated: true) }
        }
        // The titles and artists fade first, and the folder follows: the
        // panel they're on vanishes as soon as the spring starts, so a fade
        // begun alongside it would never be seen. A panel only lifts cards
        // while its labels show, so nothing can be picked up meanwhile.
        withAnimation(FolderMotion.labelsOut) { arranger.areFolderLabelsShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + FolderMotion.labelsOutLead) {
            guard arranger.isFolderExpanded, !arranger.isBusy else { return }
            MotionShine.shared.isHeld = true
            withAnimation(FolderMotion.close) {
                arranger.isFolderExpanded = false
            } completion: {
                guard !arranger.isFolderExpanded else { return }
                arranger.openFolderID = nil
                MotionShine.shared.isHeld = false
            }
        }
    }

    /// The folder is open, so its layer is drawing the tile. Not once its
    /// album has been dragged out: the layer has faded, and the tile is back
    /// in the grid the drag carries on in.
    func isTileLifted(_ folder: LibraryFolder) -> Bool {
        arranger.openFolderID == folder.folderID && !arranger.folderHiddenForDrag
    }

    /// Where `folderID`'s tile is, in the arranger's space: what an opening
    /// folder grows out of and a closing one shrinks back into. The grid's is
    /// arithmetic, like every slot in it; the list's is measured. Nil when the
    /// tile isn't on screen.
    func folderTileFrame(_ folderID: String, in arrangement: LibraryArrangement) -> CGRect? {
        if layout == .list && !arranger.isArranging {
            return arranger.rowTileFrames[folderID]
        }
        guard searchText.isEmpty,
              let index = arrangement.items.firstIndex(where: { $0.id == .folder(folderID) })
        else { return nil }
        let grid = arranger.grid
        let center = grid.coverCenter(of: index)
        return CGRect(
            x: center.x - grid.cover / 2,
            y: center.y - grid.cover / 2,
            width: grid.cover,
            height: grid.cover
        )
    }

    func rename(_ folder: LibraryFolder) {
        folderBeingRenamed = folder
        folderNameDraft = folder.name
        showFolderRename = true
    }

    // An open folder is laid out as the library is: the screen's width, the
    // library's columns and cover size (`gridLayout(for:)`), and its gutter
    // at the edges, between covers and between rows — so a cover is the same
    // size, the same distance from its neighbours, open in a folder as out of
    // one. It sat on a glass plate inset 20pt from the edges, with gaps of its
    // own, until the plate came off (2026-10-12). Rows here always show their
    // labels, so a row's gap is the gutter below its label.
    private static let folderPadding = LibraryView.gridGutter
    private static let folderGutter = LibraryView.gridGutter
    private static let folderRowSpacing = LibraryView.gridGutter

    @ViewBuilder
    func folderOverlay(_ arrangement: LibraryArrangement) -> some View {
        if let folderID = arranger.openFolderID,
           let folder = folders.first(where: { $0.folderID == folderID }) {
            openFolderView(
                folder,
                albums: arrangement.contents[folderID] ?? [],
                tile: folderTileFrame(folderID, in: arrangement)
            )
            // A layer of its own per folder, so each one starts collapsed.
            .id(folderID)
            // Taken down only at rest — collapsed over the tile, or already
            // faded for a drag — so there is never anything to fade out, and
            // a faded `UIVisualEffectView` draws wrong besides.
            .transition(.identity)
        }
    }

    /// An open folder: the library blurred behind it, the name above, and the
    /// folder's albums in a panel of their own — a grid with the same cards,
    /// the same menus and the same hold as the library's.
    private func openFolderView(_ folder: LibraryFolder, albums: [Album], tile: CGRect?) -> some View {
        GeometryReader { geo in
            // Floored: the reader's first pass is at zero, and the zoom
            // divides by the panel's width.
            let panelWidth = max(1, geo.size.width)
            let layout = gridLayout(for: panelWidth)
            let columns = layout.columns.count
            let rows = max(1, (albums.count + columns - 1) / columns)
            let contentHeight = CGFloat(rows) * (layout.coverSize + AlbumCard.labelBlock)
                + CGFloat(rows - 1) * Self.folderRowSpacing
                + 2 * Self.folderPadding
            let panelHeight = max(1, min(contentHeight, geo.size.height * 0.62))
            // Placed as a panel that tall would be, centred, but running on
            // down to the screen's foot (2026-10-28, at the user's ask): no
            // edge to cut the covers off at the bottom. The top is the one a
            // cover is dragged past to leave the folder, so that edge stays.
            let panelTop = (geo.size.height - panelHeight) / 2
            let panelReach = max(1, geo.size.height + geo.safeAreaInsets.bottom - panelTop)
            // The zoom works in the reader's own space; the tile arrives in
            // the arranger's.
            let origin = geo.frame(in: LibraryArranger.coordinateSpace).origin
            FolderZoom(
                arranger: arranger,
                tile: tile?.offsetBy(dx: -origin.x, dy: -origin.y),
                panelFrame: CGRect(
                    x: (geo.size.width - panelWidth) / 2,
                    y: panelTop,
                    width: panelWidth,
                    height: panelReach
                ),
                panelGrid: LibraryGridGeometry(
                    origin: CGPoint(x: Self.folderPadding, y: Self.folderPadding),
                    columns: columns,
                    cover: layout.coverSize,
                    columnSpacing: Self.folderGutter,
                    rowSpacing: Self.folderRowSpacing
                ),
                albums: albums,
                onClose: closeFolder
            ) {
                folderTitle(folder, width: panelWidth)
            } panel: {
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: Self.folderRowSpacing) {
                        ForEach(albums) { album in
                            albumCell(album, coverSize: layout.coverSize)
                        }
                    }
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        proxy.frame(in: LibraryArranger.coordinateSpace).origin
                    } action: { origin in
                        arranger.panel.origin = origin
                    }
                    .padding(Self.folderPadding)
                    // Room at the foot to scroll the last row clear of the
                    // home indicator.
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    // The panel's empty reach under its covers is the library
                    // as far as a tap goes: one there closes the folder, as one
                    // on the blurred library does. Without this the scroll view
                    // took it, and a short folder had no way out underneath.
                    .frame(minHeight: panelReach, alignment: .top)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: closeFolder)
                    }
                    .background(alignment: .topLeading) {
                        EnclosingScrollViewReader { arranger.panelScrollView = $0 }
                            .frame(width: 1, height: 1)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(arranger.draggedItem != nil)
                .gesture(holdGesture(for: .panel(folder.folderID), count: albums.count))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: LibraryArranger.coordinateSpace)
                } action: { frame in
                    arranger.panelViewport = frame
                }
                .onChange(of: layout.coverSize, initial: true) {
                    arranger.panel.columns = columns
                    arranger.panel.cover = layout.coverSize
                    arranger.panel.columnSpacing = Self.folderGutter
                    arranger.panel.rowSpacing = Self.folderRowSpacing
                }
            }
        }
    }

    /// The folder's name. Renamed while arranging — as on the Home Screen — and
    /// through the app's rename popup rather than an inline field, like every
    /// other rename here.
    private func folderTitle(_ folder: LibraryFolder, width: CGFloat) -> some View {
        Button {
            rename(folder)
        } label: {
            Text(folder.name)
                .font(.uiTitle2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(arranger.isArranging ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(arranger.isArranging)
        .frame(maxWidth: width)
    }
}
